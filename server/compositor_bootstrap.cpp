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
#include "wivrn_serialization.h"

#include <cerrno>
#include <iostream>
#include <sys/socket.h>

namespace wivrn
{

bool send_bootstrap(int fd, const compositor_bootstrap_message & msg)
{
	serialization_packet pkt;
	pkt.serialize(msg);

	std::vector<std::span<uint8_t>> & spans = pkt;
	size_t total = 0;
	for (const auto & span: spans)
		total += span.size();

	if (total > bootstrap_max_bytes)
	{
		std::cerr << "Bootstrap message too large: " << total << " bytes" << std::endl;
		return false;
	}

	std::vector<uint8_t> flat(total);
	size_t offset = 0;
	for (const auto & span: spans)
	{
		memcpy(flat.data() + offset, span.data(), span.size());
		offset += span.size();
	}

	ssize_t sent = ::send(fd, flat.data(), flat.size(), 0);
	if (sent != static_cast<ssize_t>(flat.size()))
	{
		std::cerr << "Bootstrap send failed: " << strerror(errno) << std::endl;
		return false;
	}

	return true;
}

std::optional<compositor_bootstrap_message> receive_bootstrap(int fd)
{
	auto memory = std::shared_ptr<uint8_t[]>(new uint8_t[bootstrap_max_bytes]);
	ssize_t n = ::recv(fd, memory.get(), bootstrap_max_bytes, 0);
	if (n == 0)
	{
		std::cerr << "Bootstrap recv: parent closed connection" << std::endl;
		return std::nullopt;
	}
	if (n < 0)
	{
		std::cerr << "Bootstrap recv failed: " << strerror(errno) << std::endl;
		return std::nullopt;
	}

	try
	{
		deserialization_packet dpkt(memory, {memory.get(), static_cast<size_t>(n)});
		return dpkt.deserialize<compositor_bootstrap_message>();
	}
	catch (const std::exception & e)
	{
		std::cerr << "Bootstrap deserialize failed: " << e.what() << std::endl;
		return std::nullopt;
	}
}

} // namespace wivrn
