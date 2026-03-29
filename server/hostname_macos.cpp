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

#include "hostname.h"

#include <unistd.h>

std::string wivrn::hostname()
{
	static std::string result = []() -> std::string {
		char buf[_POSIX_HOST_NAME_MAX];
		if (gethostname(buf, sizeof(buf)) == 0)
			return buf;
		return "macOS";
	}();
	return result;
}
