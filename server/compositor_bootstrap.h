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

#pragma once

#include "secrets.h"
#include "wivrn_packets.h"

#include <array>
#include <optional>
#include <string>

namespace wivrn
{

static constexpr size_t bootstrap_max_bytes = 2048;

struct compositor_bootstrap_message
{
	bool encrypted;
	bool has_stream;
	uint8_t encryption_state;
	std::string pin;

	std::array<uint8_t, 16> control_key;
	std::array<uint8_t, 16> control_iv_to_headset;
	std::array<uint8_t, 16> control_iv_from_headset;
	std::array<uint8_t, 16> stream_key;
	std::array<uint8_t, 8> stream_iv_header_to_headset;
	std::array<uint8_t, 8> stream_iv_header_from_headset;

	from_headset::headset_info_packet headset_info;
};

bool send_bootstrap(int fd, const compositor_bootstrap_message & msg);

std::optional<compositor_bootstrap_message> receive_bootstrap(int fd);

} // namespace wivrn
