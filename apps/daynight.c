/***************************************************************************
 *   whiskers75/__________               __   ___.
 *   Open      \______   \ ____   ____ |  | _\_ |__   _______  ___
 *   Source     |       _//  _ \_/ ___\|  |/ /| __ \ /  _ \  \/  /
 *   Jukebox    |    |   (  <_> )  \___|    < | \_\ (  <_> > <  <
 *   Firmware   |____|_  /\____/ \___  >__|_ \|___  /\____/__/\_ \
 *                     \/            \/     \/    \/            \/
 * Day/Night code as requested by rbhawaii.
 *
 * Copyright (C) 2013 whiskers75
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
 * KIND, either express or implied.
 *
 ****************************************************************************/
 
#include "settings.h"
#include "timefuncs.h"
#include "backlight.h"
int dn_hour; // A var to store the hour in

bool daynight() {
    #if CONFIG_RTC && #ifdef HAVE_BACKLIGHT_BRIGHTNESS
        if (global_settings.dnenabled == true) {
            dn_hour = get_time()->hour;
            if (dn_hour > global_settings.night) {
                backlight_set_brightness(global_settings.nightbrightness)
                return true;
            }
            else {
                backlight_set_brightness(global_settings.brightness)
                return true;
            }
        }
        else {
            return false;
        }
    #else
    return false
    #endif
}