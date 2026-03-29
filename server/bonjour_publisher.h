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

#include <dispatch/dispatch.h>
#include <dns_sd.h>
#include <map>
#include <string>

namespace wivrn
{

class bonjour_publisher
{
	DNSServiceRef service_ref = nullptr;
	dispatch_source_t read_source = nullptr;

	static void register_callback(
	        DNSServiceRef sdRef,
	        DNSServiceFlags flags,
	        DNSServiceErrorType errorCode,
	        const char * name,
	        const char * regtype,
	        const char * domain,
	        void * context);

public:
	bonjour_publisher(
	        const std::string & name,
	        const std::string & type,
	        int port,
	        const std::map<std::string, std::string> & txt = {});

	bonjour_publisher(const bonjour_publisher &) = delete;
	bonjour_publisher & operator=(const bonjour_publisher &) = delete;
	~bonjour_publisher();
};

} // namespace wivrn
