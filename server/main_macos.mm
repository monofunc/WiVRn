/*
 * WiVRn VR streaming
 * Copyright (C) 2026 Mono <81423605+monofunc@users.noreply.github.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include "active_runtime.h"
#include "bonjour_publisher.h"
#include "compositor_bootstrap.h"
#include "driver/configuration.h"
#include "driver/wivrn_connection.h"
#include "hostname.h"
#include "protocol_version.h"
#include "secrets.h"
#include "sleep_inhibitor.h"
#include "start_application.h"
#include "version.h"
#include "wivrn_ipc.h"
#include "wivrn_packets.h"
#include "wivrn_sockets.h"

#include <cinttypes>
#include <mach-o/dyld.h>

#include <CLI/CLI.hpp>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <iostream>
#include <libgen.h>
#include <optional>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

extern char ** environ;

using namespace wivrn;

namespace wivrn
{
std::unique_ptr<children_manager> create_children_manager(std::function<void()>);
}

namespace
{

// Global state
std::unique_ptr<TCPListener> listener;
std::optional<typed_socket<UnixDatagram, from_monado::packets, to_monado::packets>> wivrn_ipc_socket_main_loop;
std::optional<bonjour_publisher> publisher;
std::optional<active_runtime> runtime_setter;
std::optional<sleep_inhibitor> inhibitor;
std::unique_ptr<children_manager> children;
std::optional<std::jthread> connection_thread;

pid_t server_pid = -1;
dispatch_source_t server_proc_source = nullptr;
dispatch_source_t listener_source = nullptr;
dispatch_source_t control_source = nullptr;
int control_pipe_fds[2] = {-1, -1};

bool quitting = false;
wivrn_connection::encryption_state enc_state = wivrn_connection::encryption_state::enabled;
std::string pin;

std::chrono::milliseconds delay_next_try{10};
const std::chrono::milliseconds default_delay_next_try{10};

// Forward declarations
void update_fsm();
void start_listening(const configuration & config);
void stop_listening();
void start_publishing(const configuration & config);
void stop_publishing();
void kill_server();

std::string get_compositor_path()
{
	char path[PATH_MAX];
	uint32_t size = sizeof(path);
	if (_NSGetExecutablePath(path, &size) != 0)
		throw std::runtime_error("executable path too long");
	std::string dir = dirname(path);
	return dir + "/wivrn-compositor";
}

pid_t spawn_compositor(int ipc_fd, int tcp_fd, int udp_fd, bool has_stream, const std::optional<secrets> & crypto, wivrn_connection::encryption_state enc, const std::string & pin_str, const from_headset::headset_info_packet & headset_info, const configuration & config)
{
	// Move source fds to safe range (>=10) to avoid collision with targets 3,4,5
	auto safe_dup = [](int fd) -> int {
		if (fd < 0)
			return fd;
		if (fd >= 3 && fd <= 5)
		{
			int new_fd = fcntl(fd, F_DUPFD, 10);
			if (new_fd < 0)
			{
				std::cerr << "safe_dup: fcntl(F_DUPFD) failed for fd " << fd << ": " << strerror(errno) << std::endl;
				return -1;
			}
			close(fd);
			return new_fd;
		}
		return fd;
	};
	ipc_fd = safe_dup(ipc_fd);
	tcp_fd = safe_dup(tcp_fd);
	if (has_stream)
		udp_fd = safe_dup(udp_fd);
	control_pipe_fds[0] = safe_dup(control_pipe_fds[0]);

	fcntl(ipc_fd, F_SETFD, 0);
	fcntl(tcp_fd, F_SETFD, 0);
	if (has_stream)
		fcntl(udp_fd, F_SETFD, 0);

	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, ipc_fd, 3);
	posix_spawn_file_actions_adddup2(&actions, tcp_fd, 4);
	if (has_stream)
		posix_spawn_file_actions_adddup2(&actions, udp_fd, 5);
	posix_spawn_file_actions_addclose(&actions, ipc_fd);
	posix_spawn_file_actions_addclose(&actions, tcp_fd);
	if (has_stream)
		posix_spawn_file_actions_addclose(&actions, udp_fd);
	posix_spawn_file_actions_addclose(&actions, control_pipe_fds[0]);

	posix_spawnattr_t attr;
	posix_spawnattr_init(&attr);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
	posix_spawnattr_setpgroup(&attr, 0);

	std::vector<std::string> env_storage;
	std::vector<char *> envp;
	for (char ** e = environ; *e; ++e)
		env_storage.emplace_back(*e);
	auto set_or_add = [&](const char * key, const char * val) {
		std::string prefix = std::string(key) + "=";
		for (auto & s: env_storage)
		{
			if (s.starts_with(prefix))
				return;
		}
		env_storage.push_back(prefix + val);
	};
	set_or_add("XRT_COMPOSITOR_SCALE_PERCENTAGE", "100");
	set_or_add("XRT_COMPOSITOR_COMPUTE", "1");
	envp.reserve(env_storage.size());
	for (auto & s: env_storage)
		envp.push_back(s.data());
	envp.push_back(nullptr);

	std::string path = get_compositor_path();
	const char * argv[] = {path.c_str(), nullptr};

	pid_t pid;
	int err = posix_spawn(&pid, path.c_str(), &actions, &attr, const_cast<char **>(argv), envp.data());

	posix_spawn_file_actions_destroy(&actions);
	posix_spawnattr_destroy(&attr);

	if (err != 0)
	{
		std::cerr << "Failed to spawn compositor: " << strerror(err) << std::endl;
		close(ipc_fd);
		close(tcp_fd);
		if (has_stream && udp_fd >= 0)
			close(udp_fd);
		return -1;
	}

	compositor_bootstrap_message bootstrap{
	        .encrypted = enc != wivrn_connection::encryption_state::disabled,
	        .has_stream = has_stream,
	        .encryption_state = static_cast<uint8_t>(enc),
	        .pin = pin_str,
	};
	if (crypto)
	{
		bootstrap.control_key = crypto->control_key;
		bootstrap.control_iv_to_headset = crypto->control_iv_to_headset;
		bootstrap.control_iv_from_headset = crypto->control_iv_from_headset;
		bootstrap.stream_key = crypto->stream_key;
		bootstrap.stream_iv_header_to_headset = crypto->stream_iv_header_to_headset;
		bootstrap.stream_iv_header_from_headset = crypto->stream_iv_header_from_headset;
	}
	bootstrap.headset_info = headset_info;
	if (!send_bootstrap(control_pipe_fds[0], bootstrap))
	{
		std::cerr << "Failed to send bootstrap data to compositor" << std::endl;
		kill(pid, SIGKILL);
		waitpid(pid, nullptr, 0);
		close(ipc_fd);
		close(tcp_fd);
		if (has_stream && udp_fd >= 0)
			close(udp_fd);
		return -1;
	}

	// Close parent's copies of child-bound fds (child has its own via dup2)
	close(ipc_fd);
	close(tcp_fd);
	if (has_stream && udp_fd >= 0)
		close(udp_fd);

	std::cerr << "Compositor started, PID " << pid << std::endl;
	return pid;
}

void start_server(const configuration & config)
{
	auto & conn = *connection;
	auto info = conn.info();
	bool has_udp = conn.has_stream();

	auto crypto = conn.get_secrets();

	// Release fds from their owning objects BEFORE spawn_compositor.
	// spawn_compositor's safe_dup will close originals if in range [3,5],
	// which would corrupt the socket objects. release() sets internal fd=-1
	// so destructors won't close/shutdown the fds we pass to the child.
	int tcp_fd = conn.release_tcp_fd();
	int udp_fd = has_udp ? conn.release_udp_fd() : -1;
	int ipc_fd = wivrn_ipc_socket_monado ? wivrn_ipc_socket_monado->release() : control_pipe_fds[1];

	// Same release() pattern for the parent-end IPC socket
	wivrn_ipc_socket_main_loop->release();
	wivrn_ipc_socket_main_loop.reset();

	server_pid = spawn_compositor(ipc_fd,
	                              tcp_fd,
	                              udp_fd,
	                              has_udp,
	                              crypto,
	                              enc_state,
	                              pin,
	                              info,
	                              config);

	// Reconstruct parent-end IPC socket with the (possibly new) fd
	wivrn_ipc_socket_main_loop.emplace(control_pipe_fds[0]);

	if (server_pid < 0)
	{
		wivrn_ipc_socket_main_loop.reset();
		wivrn_ipc_socket_monado.reset();
		connection.reset();
		update_fsm();
		return;
	}

	connection.reset();
	wivrn_ipc_socket_monado.reset();

	inhibitor.emplace();
	runtime_setter.emplace();

	server_proc_source = dispatch_source_create(
	        DISPATCH_SOURCE_TYPE_PROC,
	        server_pid,
	        DISPATCH_PROC_EXIT,
	        dispatch_get_main_queue());

	dispatch_source_set_event_handler(server_proc_source, ^{
	  int status;
	  waitpid(server_pid, &status, 0);
	  display_child_status(status, "Compositor");

	  dispatch_source_cancel(server_proc_source);
	  dispatch_release(server_proc_source);
	  server_proc_source = nullptr;
	  server_pid = -1;

	  inhibitor.reset();
	  runtime_setter.reset();
	  wivrn_ipc_socket_main_loop.reset();
	  if (control_source)
	  {
		  dispatch_source_cancel(control_source);
		  dispatch_release(control_source);
		  control_source = nullptr;
	  }

	  update_fsm();
	});

	dispatch_resume(server_proc_source);

	control_source = dispatch_source_create(
	        DISPATCH_SOURCE_TYPE_READ,
	        control_pipe_fds[0],
	        0,
	        dispatch_get_main_queue());

	dispatch_source_set_event_handler(control_source, ^{
	  auto packet = wivrn_ipc_socket_main_loop->receive();
	  if (!packet)
		  return;

	  std::visit(
		  [](auto && p) {
			  using T = std::decay_t<decltype(p)>;
			  if constexpr (std::is_same_v<T, from_monado::headset_connected>)
			  {
				  stop_publishing();
			  }
			  else if constexpr (std::is_same_v<T, from_monado::headset_disconnected>)
			  {
				  auto config = configuration();
				  start_publishing(config);
			  }
		  },
		  *packet);
	});

	dispatch_resume(control_source);
}

void headset_connected_success()
{
	connection_thread.reset();

	if (enc_state == wivrn_connection::encryption_state::pairing)
		enc_state = wivrn_connection::encryption_state::enabled;

	init_cleanup_functions();

	auto config = configuration();
	start_server(config);

	if (server_pid < 0)
		return;

	if (!config.application.empty())
		children->start_application(config.application);

	delay_next_try = default_delay_next_try;
}

void headset_connected_failed()
{
	connection_thread.reset();
	connection.reset();
	update_fsm();
}

void headset_connected_incorrect_pin()
{
	connection_thread.reset();
	connection.reset();
	delay_next_try *= 2;
	update_fsm();
}

void headset_connected()
{
	if (server_proc_source || connection_thread || !listener)
		return;

	auto [tcp, addr] = listener->accept();
	stop_listening();
	stop_publishing();

	if (socketpair(AF_UNIX, SOCK_DGRAM, 0, control_pipe_fds) < 0)
	{
		perror("socketpair");
		update_fsm();
		return;
	}
	fcntl(control_pipe_fds[0], F_SETFD, FD_CLOEXEC);
	fcntl(control_pipe_fds[1], F_SETFD, FD_CLOEXEC);
	wivrn_ipc_socket_main_loop.emplace(control_pipe_fds[0]);
	wivrn_ipc_socket_monado.emplace(control_pipe_fds[1]);

	connection_thread.emplace(
	        [](std::stop_token stop_token, TCP && tcp, std::string pin, wivrn_connection::encryption_state enc_state) {
		        try
		        {
			        connection = std::make_unique<wivrn_connection>(stop_token, enc_state, pin, std::move(tcp));
			        dispatch_async(dispatch_get_main_queue(), ^{
				  headset_connected_success();
			        });
		        }
		        catch (wivrn::incorrect_pin &)
		        {
			        dispatch_async(dispatch_get_main_queue(), ^{
				  headset_connected_incorrect_pin();
			        });
		        }
		        catch (std::exception & e)
		        {
			        std::cerr << "Connection failed: " << e.what() << std::endl;
			        dispatch_async(dispatch_get_main_queue(), ^{
				  headset_connected_failed();
			        });
		        }
	        },
	        std::move(tcp),
	        pin,
	        enc_state);
}

void start_listening(const configuration & config)
{
	if (listener)
		return;

	listener = std::make_unique<TCPListener>(config.port);

	listener_source = dispatch_source_create(
	        DISPATCH_SOURCE_TYPE_READ,
	        listener->get_fd(),
	        0,
	        dispatch_get_main_queue());

	dispatch_source_set_event_handler(listener_source, ^{
	  headset_connected();
	});

	dispatch_resume(listener_source);
}

void stop_listening()
{
	if (listener_source)
	{
		dispatch_source_cancel(listener_source);
		dispatch_release(listener_source);
		listener_source = nullptr;
	}
	listener.reset();
}

void start_publishing(const configuration & config)
{
	if (publisher)
		return;

	char protocol_string[17];
	snprintf(protocol_string, sizeof(protocol_string), "%016" PRIx64, wivrn::protocol_version);
	std::map<std::string, std::string> TXT = {
	        {"protocol", protocol_string},
	        {"version", wivrn::display_version()},
	        {"cookie", server_cookie()},
	};

	try
	{
		publisher.emplace(config.hostname, "_wivrn._tcp", config.port, TXT);
	}
	catch (std::exception & e)
	{
		std::cerr << "Failed to publish service: " << e.what() << std::endl;
	}
}

void stop_publishing()
{
	publisher.reset();
}

void kill_server()
{
	if (server_pid <= 0)
		return;

	if (wivrn_ipc_socket_main_loop)
		wivrn_ipc_socket_main_loop->send(to_monado::stop{});

	pid_t pid = server_pid;
	dispatch_after(
	        dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
	        dispatch_get_main_queue(),
	        ^{
		  if (server_pid == pid)
			  kill(-pid, SIGTERM);
	        });
}

void update_fsm()
{
	bool server_running = (server_proc_source != nullptr) || connection_thread.has_value();
	bool app_running = children && children->running();

	if (quitting)
	{
		// Detach connection thread to avoid blocking dispatch_main() on join
		if (connection_thread.has_value())
		{
			connection_thread->request_stop();
			connection_thread->detach();
		}
		connection_thread.reset();

		// Recompute after connection_thread is gone
		server_running = (server_proc_source != nullptr);

		if (server_running)
			kill_server();
		if (app_running)
			children->stop();
		if (!server_running && !app_running)
		{
			children.reset();
			exit(0);
		}
		return;
	}

	if (!server_running && app_running)
		children->stop();

	if (!server_running)
	{
		runtime_setter.reset();
		inhibitor.reset();

		int64_t delay_ns = delay_next_try.count() * NSEC_PER_MSEC;
		dispatch_after(
		        dispatch_time(DISPATCH_TIME_NOW, delay_ns),
		        dispatch_get_main_queue(),
		        ^{
			  auto config = configuration();
			  start_listening(config);
			  start_publishing(config);
		        });
	}
}

} // namespace

// Connection defined in wivrn_ipc.cpp
std::optional<wivrn::typed_socket<wivrn::UnixDatagram, to_monado::packets, from_monado::packets>> wivrn_ipc_socket_monado;

int main(int argc, char ** argv)
{
	CLI::App app{"WiVRn macOS server"};
	auto no_encrypt = app.add_flag("--no-encrypt")->description("disable encryption")->group("Debug");
	app.parse(argc, argv);

	if (*no_encrypt)
		enc_state = wivrn_connection::encryption_state::disabled;

	std::cerr << "WiVRn " << wivrn::display_version() << " starting" << std::endl;

	auto config = configuration();
	std::cerr << "Hostname: " << wivrn::hostname() << std::endl;
	std::cerr << "Port: " << config.port << std::endl;

	children = create_children_manager(update_fsm);

	signal(SIGPIPE, SIG_IGN);
	signal(SIGINT, SIG_IGN);
	signal(SIGTERM, SIG_IGN);

	dispatch_source_t sig_int = dispatch_source_create(
	        DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
	dispatch_source_t sig_term = dispatch_source_create(
	        DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());

	dispatch_source_set_event_handler(sig_int, ^{
	  std::cerr << "Interrupted" << std::endl;
	  quitting = true;
	  update_fsm();
	});
	dispatch_source_set_event_handler(sig_term, ^{
	  std::cerr << "Terminated" << std::endl;
	  quitting = true;
	  update_fsm();
	});

	dispatch_resume(sig_int);
	dispatch_resume(sig_term);

	start_listening(config);
	start_publishing(config);

	dispatch_main();
}
