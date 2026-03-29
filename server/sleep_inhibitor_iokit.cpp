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

#include "sleep_inhibitor.h"

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <iostream>

sleep_inhibitor::sleep_inhibitor()
{
	IOReturn ret = IOPMAssertionCreateWithName(
	        kIOPMAssertionTypePreventUserIdleSystemSleep,
	        kIOPMAssertionLevelOn,
	        CFSTR("WiVRn VR streaming active"),
	        &assertion_id);

	if (ret != kIOReturnSuccess)
		std::cerr << "Cannot create sleep inhibitor assertion" << std::endl;
}

sleep_inhibitor::~sleep_inhibitor()
{
	if (assertion_id != kIOPMNullAssertionID)
		IOPMAssertionRelease(assertion_id);
}
