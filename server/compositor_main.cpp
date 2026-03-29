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

#include "compositor_bootstrap.h"
#include "driver/wivrn_connection.h"
#include "ipc_server_cb.h"
#include "wivrn_ipc.h"

#include <iostream>

#include <shared/ipc_protocol.h>
#include <util/u_trace_marker.h>

U_TRACE_TARGET_SETUP(U_TRACE_WHICH_SERVICE)

std::optional<wivrn::typed_socket<wivrn::UnixDatagram, to_monado::packets, from_monado::packets>> wivrn_ipc_socket_monado;

int main(int argc, char ** argv)
{
	u_trace_marker_init();

	int ipc_fd = 3;
	int tcp_fd = 4;
	int udp_fd = 5;

	auto bootstrap = wivrn::receive_bootstrap(ipc_fd);
	if (!bootstrap)
	{
		std::cerr << "Failed to receive bootstrap from parent" << std::endl;
		return EXIT_FAILURE;
	}

	wivrn_ipc_socket_monado.emplace(ipc_fd);

	wivrn::TCP tcp(tcp_fd);
	wivrn::UDP udp = bootstrap->has_stream ? wivrn::UDP(udp_fd) : wivrn::UDP(-1);

	try
	{
		connection = wivrn::wivrn_connection::from_bootstrap(
		        std::move(tcp),
		        std::move(udp),
		        *bootstrap);
	}
	catch (const std::exception & e)
	{
		std::cerr << "from_bootstrap failed: " << e.what() << std::endl;
		return EXIT_FAILURE;
	}

	ipc_server_main_info server_info{
	        .udgci = {.open = U_DEBUG_GUI_OPEN_NEVER},
	        .no_stdin = true,
	};

	wivrn::ipc_server_cb server_cb;

	try
	{
		return ipc_server_main_common(&server_info, &server_cb, nullptr);
	}
	catch (const std::exception & e)
	{
		std::cerr << "Compositor error: " << e.what() << std::endl;
		return EXIT_FAILURE;
	}
}
