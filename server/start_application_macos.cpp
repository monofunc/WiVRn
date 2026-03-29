/*
 * WiVRn VR streaming
 * Copyright (C) 2024  Guillaume Meunier <guillaume.meunier@centraliens.net>
 * Copyright (C) 2025  Patrick Nicolas <patricknicolas@laposte.net>
 * Copyright (C) 2026  Mono <81423605+monofunc@users.noreply.github.com>
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

#include "start_application.h"

#include <dispatch/dispatch.h>
#include <iostream>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char ** environ;

namespace wivrn
{

children_manager::~children_manager() {}

static std::vector<std::string> unescape_string(const std::string & app_string)
{
	std::vector<std::string> app;
	app.emplace_back();

	bool seen_backslash = false;
	bool seen_single_quote = false;
	bool seen_double_quote = false;
	for (auto c: app_string)
	{
		if (seen_backslash)
		{
			app.back() += c;
			seen_backslash = false;
		}
		else if (seen_single_quote)
		{
			if (c == '\'')
				seen_single_quote = false;
			else if (c == '\\')
				seen_backslash = true;
			else
				app.back() += c;
		}
		else if (seen_double_quote)
		{
			if (c == '"')
				seen_double_quote = false;
			else if (c == '\\')
				seen_backslash = true;
			else
				app.back() += c;
		}
		else
		{
			switch (c)
			{
				case '\\':
					seen_backslash = true;
					break;
				case '\'':
					seen_single_quote = true;
					break;
				case '"':
					seen_double_quote = true;
					break;
				case ' ':
					if (app.back() != "")
						app.emplace_back();
					break;
				default:
					app.back() += c;
			}
		}
	}

	if (app.back() == "")
		app.pop_back();

	return app;
}

void children_manager::start_application(const std::string & exec, const std::optional<std::string> & path)
{
	start_application(unescape_string(exec), path);
}

void display_child_status(int wstatus, const std::string & name)
{
	std::cerr << name << " exited, exit status " << WEXITSTATUS(wstatus);
	if (WIFSIGNALED(wstatus))
	{
		std::cerr << ", received signal " << WTERMSIG(wstatus)
		          << " (" << strsignal(WTERMSIG(wstatus)) << ")"
		          << (WCOREDUMP(wstatus) ? ", core dumped" : "") << std::endl;
	}
	else
	{
		std::cerr << std::endl;
	}
}

class posix_spawn_children : public children_manager
{
	struct child_info
	{
		dispatch_source_t proc_source;
	};
	std::unordered_map<pid_t, child_info> children;
	std::function<void()> state_changed_cb;

	void on_child_exit(pid_t pid)
	{
		int status;
		waitpid(pid, &status, 0);
		display_child_status(status, "Application");

		auto it = children.find(pid);
		if (it != children.end())
		{
			dispatch_source_cancel(it->second.proc_source);
			dispatch_release(it->second.proc_source);
			children.erase(it);
		}

		if (state_changed_cb)
			state_changed_cb();
	}

public:
	posix_spawn_children(std::function<void()> state_changed_cb) :
	        state_changed_cb(std::move(state_changed_cb)) {}

	~posix_spawn_children() override
	{
		for (auto & [pid, info]: children)
		{
			dispatch_source_cancel(info.proc_source);
			dispatch_release(info.proc_source);
			killpg(pid, SIGTERM);
		}
		children.clear();
	}

	void start_application(const std::vector<std::string> & command,
	                       const std::optional<std::string> & working_dir) override
	{
		if (command.empty())
			return;

		posix_spawn_file_actions_t actions;
		posix_spawn_file_actions_init(&actions);

		if (working_dir)
			posix_spawn_file_actions_addchdir_np(&actions, working_dir->c_str());

		posix_spawnattr_t attr;
		posix_spawnattr_init(&attr);
		posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
		posix_spawnattr_setpgroup(&attr, 0);

		std::vector<const char *> argv;
		for (const auto & arg: command)
			argv.push_back(arg.c_str());
		argv.push_back(nullptr);

		pid_t pid;
		int err = posix_spawnp(&pid,
		                       command[0].c_str(),
		                       &actions,
		                       &attr,
		                       const_cast<char **>(argv.data()),
		                       environ);

		posix_spawn_file_actions_destroy(&actions);
		posix_spawnattr_destroy(&attr);

		if (err != 0)
		{
			std::cerr << "Failed to spawn application: " << strerror(err) << std::endl;
			return;
		}

		std::cerr << "Application started, PID " << pid << std::endl;

		dispatch_source_t proc_source = dispatch_source_create(
		        DISPATCH_SOURCE_TYPE_PROC,
		        pid,
		        DISPATCH_PROC_EXIT,
		        dispatch_get_main_queue());

		dispatch_source_set_event_handler(proc_source, ^{
		  on_child_exit(pid);
		});

		dispatch_resume(proc_source);
		children[pid] = {proc_source};
	}

	bool running() const override
	{
		return !children.empty();
	}

	void stop() override
	{
		for (auto & [pid, info]: children)
		{
			killpg(pid, SIGTERM);

			pid_t child_pid = pid;
			dispatch_after(
			        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
			        dispatch_get_main_queue(),
			        ^{
				  int status;
				  if (waitpid(child_pid, &status, WNOHANG) == 0)
					  killpg(child_pid, SIGKILL);
			        });
		}
	}
};

std::unique_ptr<children_manager> create_children_manager(std::function<void()> state_changed_cb)
{
	return std::make_unique<posix_spawn_children>(std::move(state_changed_cb));
}

} // namespace wivrn
