{
while sleep 1
do 
printf .
done
} & 
export x=$!
#!/bin/sh
#             __________               __   ___.
#   Open      \______   \ ____   ____ |  | _\_ |__   _______  ___
#   Source     |       _//  _ \_/ ___\|  |/ /| __ \ /  _ \  \/  /
#   Jukebox    |    |   (  <_> )  \___|    < | \_\ (  <_> > <  <
#   Firmware   |____|_  /\____/ \___  >__|_ \|___  /\____/__/\_ \
#                     \/            \/     \/    \/            \/
#

# global CC options for all platforms
CCOPTS="-W -Wall -Wundef -O -nostdlib -ffreestanding -Wstrict-prototypes -pipe -std=gnu99"

# LD options for the core
LDOPTS=""
# LD options for the core + plugins
GLOBAL_LDOPTS=""

extradefines=""
use_logf="#undef ROCKBOX_HAS_LOGF"
use_bootchart="#undef DO_BOOTCHART"
use_logf_serial="#undef LOGF_SERIAL"

scriptver=`echo '$Revision$' | sed -e 's:\\$::g' -e 's/Revision: //'`

rbdir="/.rockbox"
bindir=
libdir=
sharedir=

thread_support="ASSEMBLER_THREADS"
app_lcd_width=
app_lcd_height=
app_lcd_orientation=

# Properly retain command line arguments containing spaces
cmdline=
for arg in "$@"; do
  case "$arg" in
    *\ *) cmdline="$cmdline \"$arg\"";;
    *)    cmdline="$cmdline $arg";;
  esac
done

#
# Begin Function Definitions
#
input() {
    read response
    echo $response
}

prefixtools () {
 prefix="$1"
 CC=${prefix}gcc
 CPP=${prefix}cpp
 WINDRES=${prefix}windres
 DLLTOOL=${prefix}dlltool
 DLLWRAP=${prefix}dllwrap
 RANLIB=${prefix}ranlib
 LD=${prefix}ld
 AR=${prefix}ar
 AS=${prefix}as
 OC=${prefix}objcopy
}

app_set_paths () {
    # setup files and paths depending on the platform
    if [ -z "$ARG_PREFIX" ]; then
        sharedir="/usr/local/share/rockbox"
        bindir="/usr/local/bin"
        libdir="/usr/local/lib"
    else
        if [ -d "$ARG_PREFIX" ]; then
            if [ -z `echo $ARG_PREFIX | grep "^/"` ]; then
                ARG_PREFIX=`realpath $ARG_PREFIX`
                if [ "0" != "$?" ]; then
                    echo "ERROR: Could not get prefix path (is realpath installed?)."
                    exit
                fi
            fi
            sharedir="$ARG_PREFIX/share/rockbox"
            bindir="$ARG_PREFIX/bin"
            libdir="$ARG_PREFIX/lib"
        else
            echo "ERROR: PREFIX directory $ARG_PREFIX does not exist"
            exit
        fi
    fi
}

# Set the application LCD size according to the following priorities:
# 1) If --lcdwidth and --lcdheight are set, use them
# 2) If a size is passed to the app_set_lcd_size() function, use that
# 3) Otherwise ask the user
app_set_lcd_size () {
    if [ -z "$ARG_LCDWIDTH" ]; then
        ARG_LCDWIDTH=$1
    fi
    if [ -z "$ARG_LCDHEIGHT" ]; then
        ARG_LCDHEIGHT=$2
    fi

    echo "Enter the LCD width (default: 320)"
    if [ -z "$ARG_LCDWIDTH" ]; then
        app_lcd_width=`input`
    else
        app_lcd_width="$ARG_LCDWIDTH"
    fi
    if [ -z "$app_lcd_width" ]; then app_lcd_width="320"; fi
    echo "Enter the LCD height (default: 480)"
    if [ -z "$ARG_LCDHEIGHT" ]; then
        app_lcd_height=`input`
    else
        app_lcd_height="$ARG_LCDHEIGHT"
    fi
    if [ -z "$app_lcd_height" ]; then app_lcd_height="480"; fi
    if [ $app_lcd_width -gt $app_lcd_height ]; then
        lcd_orientation="landscape"
    else
        lcd_orientation="portrait"
    fi
    echo "Selected $app_lcd_width x $app_lcd_height resolution ($lcd_orientation)"
    ARG_LCDWIDTH=$app_lcd_width
    ARG_LCDHEIGHT=$app_lcd_height

    app_lcd_width="#define LCD_WIDTH $app_lcd_width"
    app_lcd_height="#define LCD_HEIGHT $app_lcd_height"
}

findarmgcc() {
  prefixtools arm-elf-eabi-
  gccchoice="4.4.4"
}

# scan the $PATH for the given command
findtool(){
  file="$1"

  IFS=":"
  for path in $PATH
  do
    # echo "checks for $file in $path" >&2
    if test -f "$path/$file"; then
      echo "$path/$file"
      return
    fi
  done
  # check whether caller wants literal return value if not found
  if [ "$2" = "--lit" ]; then
    echo "$file"
  fi
}

# scan the $PATH for sdl-config - check whether for a (cross-)win32
# sdl as requested
findsdl(){
  # sdl-config might (not) be prefixed for cross compiles so try both.
  files="${CROSS_COMPILE}sdl-config:sdl-config"
  winbuild="$1"

  IFS=":"
  for file in $files
  do
    for path in $PATH
    do
      #echo "checks for $file in $path" >&2
      if test -f "$path/$file"; then
        if [ "0" != `$path/$file --libs |grep -c mwindows` ]; then
          if [ "yes" = "${winbuild}" ]; then
            echo "$path/$file"
            return
          fi
        else
          if [ "yes" != "${winbuild}" ]; then
            echo "$path/$file"
            return
          fi
        fi
      fi
    done
  done
}

# check for availability of sigaltstack to support our thread engine
check_sigaltstack() {
   cat >$tmpdir/check_threads.c <<EOF
#include <signal.h>
int main(int argc, char **argv)
{
#ifndef NULL
  #define NULL (void*)0
#endif
  sigaltstack(NULL, NULL);
  return 0;
}
EOF
   $CC -o $tmpdir/check_threads $tmpdir/check_threads.c 1> /dev/null
   result=$?
   rm -rf $tmpdir/check_threads*
   echo $result
}

# check for availability of Fiber on Win32 to support our thread engine
check_fiber() {
   cat >$tmpdir/check_threads.c <<EOF
#include <windows.h>
int main(int argc, char **argv)
{
  ConvertThreadToFiber(NULL);
  return 0;
}
EOF
   $CC -o $tmpdir/check_threads $tmpdir/check_threads.c 2>/dev/null
   result=$?
   rm -rf $tmpdir/check_threads*
   echo $result
}

simcc () {

 # default tool setup for native building
 prefixtools "$CROSS_COMPILE"
 ARG_ARM_THUMB=0 # can't use thumb in native builds

 # unset arch if already set shcc() and friends
 arch=
 arch_version=

 app_type=$1
 winbuild=""
 GCCOPTS=`echo $CCOPTS | sed -e s/-ffreestanding// -e s/-nostdlib// -e s/-Wundef//`

 GCCOPTS="$GCCOPTS -fno-builtin -g"
 GCCOPTIMIZE=''
 LDOPTS="$LDOPTS -lm" # button-sdl.c uses sqrt()
 sigaltstack=""
 fibers=""
 endian="" # endianess of the dap doesnt matter here

 # default output binary name, don't override app_get_platform()
 if [ "$app_type" != "sdl-app" ]; then
    output="rockboxui"
 fi

 # default share option, override below if needed
 SHARED_LDFLAG="-shared"
 SHARED_CFLAGS="-fPIC -fvisibility=hidden"

 if [ "$win32crosscompile" = "yes" ]; then
   # We are crosscompiling
   # add cross-compiler option(s)
   LDOPTS="$LDOPTS -mconsole"
   output="$output.exe"
   winbuild="yes"
   CROSS_COMPILE=${CROSS_COMPILE:-"i586-mingw32msvc-"}
   SHARED_CFLAGS=''
   prefixtools "$CROSS_COMPILE"
   fibers=`check_fiber`
   endian="little" # windows is little endian
   echo "Enabling MMX support"
   GCCOPTS="$GCCOPTS -mmmx"
 else
 case $uname in
   CYGWIN*)
   echo "Cygwin host detected"

   fibers=`check_fiber`
   LDOPTS="$LDOPTS -mconsole"
   output="$output.exe"
   winbuild="yes"
   SHARED_CFLAGS=''
   ;;

   MINGW*)
   echo "MinGW host detected"

   fibers=`check_fiber`
   LDOPTS="$LDOPTS -mconsole"
   output="$output.exe"
   winbuild="yes"
   ;;

   Linux)
   sigaltstack=`check_sigaltstack`
   echo "Linux host detected"
   LDOPTS="$LDOPTS -ldl"
   ;;

   FreeBSD)
   sigaltstack=`check_sigaltstack`
   echo "FreeBSD host detected"
   LDOPTS="$LDOPTS -ldl"
   ;;

   Darwin)
   sigaltstack=`check_sigaltstack`
   echo "Darwin host detected"
   LDOPTS="$LDOPTS -ldl"
   SHARED_LDFLAG="-dynamiclib -Wl\,-single_module"
   ;;

   SunOS)
   sigaltstack=`check_sigaltstack`
   echo "*Solaris host detected"

   GCCOPTS="$GCCOPTS -fPIC"
   LDOPTS="$LDOPTS -ldl"
   ;;

   *)
   echo "[ERROR] Unsupported system: $uname, fix configure and retry"
   exit 1
   ;;
 esac
 fi

 if [ "$winbuild" != "yes" ]; then
   GLOBAL_LDOPTS="$GLOBAL_LDOPTS -Wl,-z,defs"
   if [ "`uname -m`" = "i686" ]; then
     echo "Enabling MMX support"
     GCCOPTS="$GCCOPTS -mmmx"
   fi
 fi

 sdl=`findsdl $winbuild`

 if [ -n `echo $app_type | grep "sdl"` ]; then
    if [ -z "$sdl" ]; then
        echo "configure didn't find sdl-config, which indicates that you"
        echo "don't have SDL (properly) installed. Please correct and"
        echo "re-run configure!"
        exit 2
    else 
        # generic sdl-config checker
        GCCOPTS="$GCCOPTS `$sdl --cflags`"
        LDOPTS="$LDOPTS `$sdl --libs`"
    fi
 fi
 

 GCCOPTS="$GCCOPTS -I\$(SIMDIR)"
 # x86_64 supports MMX by default

  if [ "$endian" = "" ]; then
    id=$$
    cat >$tmpdir/conftest-$id.c <<EOF
#include <stdio.h>
int main(int argc, char **argv)
{
int var=0;
char *varp = (char *)&var;
*varp=1;

printf("%d\n", var);
return 0;
}
EOF
    $CC -o $tmpdir/conftest-$id $tmpdir/conftest-$id.c 2>/dev/null
    # when cross compiling, the endianess cannot be detected because the above program doesn't run
    # on the local machine. assume little endian but print a warning
    endian=`$tmpdir/conftest-$id 2> /dev/null`
    if [ "$endian" != "" ] && [ $endian -gt "1" ]; then
      # big endian
      endian="big"
    else
      # little endian
      endian="little"
    fi
  fi

 if [ "$CROSS_COMPILE" != "" ]; then
   echo "WARNING: Cross Compiling, cannot detect endianess. Assuming $endian endian!"
 fi

 if [ "$app_type" = "sdl-sim" ]; then
   echo "Simulator environment deemed $endian endian"
 elif [ "$app_type" = "sdl-app" ]; then
   echo "Application environment deemed $endian endian"
 elif [ "$app_type" = "checkwps" ]; then
   echo "CheckWPS environment deemed $endian endian"
 fi

 # use wildcard here to make it work even if it was named *.exe like
 # on cygwin
 rm -f $tmpdir/conftest-$id*

 thread_support=
 if [ -z "$ARG_THREAD_SUPPORT" ] || [ "$ARG_THREAD_SUPPORT" = "0" ]; then
   if [ "$sigaltstack" = "0" ]; then
     thread_support="HAVE_SIGALTSTACK_THREADS"
     LDOPTS="$LDOPTS -lpthread" # pthread needed
     echo "Selected sigaltstack threads"
   elif [ "$fibers" = "0" ]; then
     thread_support="HAVE_WIN32_FIBER_THREADS"
     echo "Selected Win32 Fiber threads"
   fi
 fi

 if [ -n `echo $app_type | grep "sdl"` ] && [ -z "$thread_support" ] \
    && [ "$ARG_THREAD_SUPPORT" != "0" ]; then
   thread_support="HAVE_SDL_THREADS"
   if [ "$ARG_THREAD_SUPPORT" = "1" ]; then
     echo "Selected SDL threads"
   else
     echo "WARNING: Falling back to SDL threads"
   fi
 fi
}

#
# functions for setting up cross-compiler names and options
# also set endianess and what the exact recommended gcc version is
# the gcc version should most likely match what versions we build with
# rockboxdev.sh
#
shcc () {
 prefixtools sh-elf-
 GCCOPTS="$CCOPTS -m1"
 GCCOPTIMIZE="-fomit-frame-pointer -fschedule-insns"
 endian="big"
 gccchoice="4.0.3"
}

calmrisccc () {
 prefixtools calmrisc16-unknown-elf-
 GCCOPTS="-Wl\,--no-check-sections $CCOPTS"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="big"
}

coldfirecc () {
 prefixtools m68k-elf-
 GCCOPTS="$CCOPTS -mcpu=5249 -malign-int -mstrict-align"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="big"
 gccchoice="4.5.2"
}

arm7tdmicc () {
 findarmgcc
 GCCOPTS="$CCOPTS -mcpu=arm7tdmi"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="little"
}

arm9tdmicc () {
 findarmgcc
 GCCOPTS="$CCOPTS -mcpu=arm9tdmi"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="little"
}

arm940tbecc () {
 findarmgcc
 GCCOPTS="$CCOPTS -mbig-endian -mcpu=arm940t"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="big"
}

arm940tcc () {
 findarmgcc
 GCCOPTS="$CCOPTS -mcpu=arm940t"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="little"
}

arm946cc () {
 findarmgcc
 GCCOPTS="$CCOPTS -mcpu=arm9e"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="little"
}

arm926ejscc () {
 findarmgcc
 GCCOPTS="$CCOPTS -mcpu=arm926ej-s"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="little"
}

arm1136jfscc () {
 findarmgcc
 GCCOPTS="$CCOPTS -mcpu=arm1136jf-s"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="little"
}

arm1176jzscc () {
 findarmgcc
 GCCOPTS="$CCOPTS -mcpu=arm1176jz-s"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="little"
}

arm7ejscc () {
 findarmgcc
 GCCOPTS="$CCOPTS -march=armv5te"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="little"
}

mipselcc () {
 prefixtools mipsel-elf-
 # mips is predefined, but we want it for paths. use __mips instead
 GCCOPTS="$CCOPTS -march=mips32 -mtune=r4600 -mno-mips16 -mno-long-calls -Umips"
 GCCOPTS="$GCCOPTS -ffunction-sections -msoft-float -G 0 -Wno-parentheses"
 GCCOPTIMIZE="-fomit-frame-pointer"
 endian="little"
 gccchoice="4.1.2"
}

maemocc () {
 # Scratchbox sets up "gcc" based on the active target
 prefixtools ""

 GCCOPTS=`echo $CCOPTS | sed -e s/-ffreestanding// -e s/-nostdlib// -e s/-Wundef//`
 GCCOPTS="$GCCOPTS -fno-builtin -g -I\$(SIMDIR)"
 GCCOPTIMIZE=''
 LDOPTS="-lm -ldl $LDOPTS"
 GLOBAL_LDOPTS="$GLOBAL_LDOPTS -Wl,-z,defs"
 SHARED_LDFLAG="-shared"
 SHARED_CFLAGS=''
 endian="little"
 thread_support="HAVE_SIGALTSTACK_THREADS"

 is_n900=0
 # Determine maemo version
 if pkg-config --atleast-version=5 maemo-version; then
    if [ "$1" == "4" ]; then
        echo "ERROR: Maemo 4 SDK required."
        exit 1
    fi
    extradefines="$extradefines -DMAEMO5"
    echo "Found N900 maemo version"
    is_n900=1
 elif pkg-config --atleast-version=4 maemo-version; then
    if [ "$1" == "5" ]; then
        echo "ERROR: Maemo 5 SDK required."
        exit 1
    fi
    extradefines="$extradefines -DMAEMO4"
    echo "Found N8xx maemo version"
 else
    echo "Unable to determine maemo version. Is the maemo-version-dev package installed?"
    exit 1
 fi

 # SDL
 if [ $is_n900 -eq 1 ]; then
    GCCOPTS="$GCCOPTS `pkg-config --cflags sdl`"
    LDOPTS="$LDOPTS `pkg-config --libs sdl`"
 else
    GCCOPTS="$GCCOPTS `sdl-config --cflags`"
    LDOPTS="$LDOPTS `sdl-config --libs`"
 fi

 # glib and libosso support
 GCCOPTS="$GCCOPTS `pkg-config --cflags libosso glib-2.0 gthread-2.0`"
 LDOPTS="$LDOPTS `pkg-config --libs libosso glib-2.0 gthread-2.0`"

 # libhal support: Battery monitoring
 GCCOPTS="$GCCOPTS `pkg-config --cflags hal`"
 LDOPTS="$LDOPTS `pkg-config --libs hal`"

 GCCOPTS="$GCCOPTS -O2 -fno-strict-aliasing"
 if [ $is_n900 -eq 1 ]; then
    # gstreamer support: Audio output.
    GCCOPTS="$GCCOPTS `pkg-config --cflags gstreamer-base-0.10 gstreamer-plugins-base-0.10 gstreamer-app-0.10`"
    LDOPTS="$LDOPTS `pkg-config --libs gstreamer-base-0.10 gstreamer-plugins-base-0.10 gstreamer-app-0.10`"

    # N900 specific: libplayback support
    GCCOPTS="$GCCOPTS `pkg-config --cflags libplayback-1`"
    LDOPTS="$LDOPTS `pkg-config --libs libplayback-1`"

    # N900 specific: Enable ARMv7 NEON support
    if sb-conf show -A |grep -q -i arm; then
        echo "Detected ARM target"
        GCCOPTS="$GCCOPTS -mcpu=cortex-a8 -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp"
        extradefines="$extradefines -DMAEMO_ARM_BUILD"
    else
        echo "Detected x86 target"
    fi
 else
    # N8xx specific: Enable armv5te instructions
    if sb-conf show -A |grep -q -i arm; then
        echo "Detected ARM target"
        GCCOPTS="$GCCOPTS -mcpu=arm1136jf-s -mfloat-abi=softfp -mfpu=vfp"
        extradefines="$extradefines -DMAEMO_ARM_BUILD"
    else
        echo "Detected x86 target"
    fi
 fi
}

pandoracc () {
 # Note: The new "Ivanovic" pandora toolchain is not able to compile rockbox.
 #       You have to use the sebt3 toolchain:
 #       http://www.gp32x.com/board/index.php?/topic/58490-yactfeau/

 PNDSDK="/usr/local/angstrom/arm"
 if [ ! -x $PNDSDK/bin/arm-angstrom-linux-gnueabi-gcc ]; then
     echo "Pandora SDK gcc not found in $PNDSDK/bin/arm-angstrom-linux-gnueabi-gcc"
     exit
 fi

 PATH=$PNDSDK/bin:$PATH:$PNDSDK/arm-angstrom-linux-gnueabi/usr/bin
 PKG_CONFIG_PATH=$PNDSDK/arm-angstrom-linux-gnueabi/usr/lib/pkgconfig
 LDOPTS="-L$PNDSDK/arm-angstrom-linux-gnueabi/usr/lib -Wl,-rpath,$PNDSDK/arm-angstrom-linux-gnueabi/usr/lib $LDOPTS"
 PKG_CONFIG="pkg-config"

 GCCOPTS=`echo $CCOPTS | sed -e s/-ffreestanding// -e s/-nostdlib// -e s/-Wundef//`
 GCCOPTS="$GCCOPTS -fno-builtin -g -I\$(SIMDIR)"
 GCCOPTIMIZE=''
 LDOPTS="-lm -ldl $LDOPTS"
 GLOBAL_LDOPTS="$GLOBAL_LDOPTS -Wl,-z,defs"
 SHARED_LDFLAG="-shared"
 SHARED_CFLAGS=''
 endian="little"
 thread_support="HAVE_SIGALTSTACK_THREADS"

 # Include path
 GCCOPTS="$GCCOPTS -I$PNDSDK/arm-angstrom-linux-gnueabi/usr/include"

 # Set up compiler
 gccchoice="4.3.3"
 prefixtools "$PNDSDK/bin/arm-angstrom-linux-gnueabi-"

 # Detect SDL
 GCCOPTS="$GCCOPTS `$PNDSDK/bin/sdl-config --cflags`"
 LDOPTS="$LDOPTS `$PNDSDK/bin/sdl-config --libs`"

 # Compiler options
 GCCOPTS="$GCCOPTS -O2 -fno-strict-aliasing"
 GCCOPTS="$GCCOPTS -march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp"
 GCCOPTS="$GCCOPTS -ffast-math -fsingle-precision-constant"
}

ypr0cc () {

 GCCOPTS=`echo $CCOPTS | sed -e s/-ffreestanding// -e s/-nostdlib//`
 GCCOPTIMIZE=''
 LDOPTS="-lasound -lpthread -lm -ldl -lrt $LDOPTS"
 GLOBAL_LDOPTS="$GLOBAL_LDOPTS -Wl,-z,defs"
 SHARED_LDFLAG="-shared"
 SHARED_CFLAGS=''
 endian="little"
 app_type="ypr0"

 # Include path
 GCCOPTS="$GCCOPTS  -D_GNU_SOURCE=1 -U_FORTIFY_SOURCE -D_REENTRANT"

 # Set up compiler
 gccchoice="4.4.6"
 prefixtools "arm-ypr0-linux-gnueabi-"
}

androidcc () {
    if [ -z "$ANDROID_SDK_PATH" ]; then
        echo "ERROR: You need the Android SDK installed and have the ANDROID_SDK_PATH"
        echo "environment variable point to the root directory of the Android SDK."
        exit
    fi
    if [ -z "$ANDROID_NDK_PATH" ]; then
        echo "ERROR: You need the Android NDK installed (r5 or higher) and have the ANDROID_NDK_PATH"
        echo "environment variable point to the root directory of the Android NDK."
        exit
    fi
    buildhost=$(uname | tr "[:upper:]" "[:lower:]")
    GCCOPTS=`echo $CCOPTS | sed -e s/-ffreestanding// -e s/-nostdlib// -e s/-Wundef//`
    LDOPTS="$LDOPTS -Wl,-soname,librockbox.so -shared -ldl -llog"
    GLOBAL_LDOPTS="-Wl,-z,defs -Wl,-z,noexecstack -shared"
    ANDROID_ARCH=$1 # for android.make too
    # arch dependant stuff
    case $ANDROID_ARCH in
        armeabi)
            endian="little"
            gccchoice="4.4.3"
            gcctarget="arm-linux-androideabi-"
            # sigaltstack is not available in pre-android-9, however asm
            # threads work fine so far
            thread_support="ASSEMBLER_THREADS"
            GCCOPTS="$GCCOPTS -march=armv5te -mtune=xscale -msoft-float -fomit-frame-pointer \
                    --sysroot=$ANDROID_NDK_PATH/platforms/android-5/arch-arm"
            LDOPTS="$LDOPTS --sysroot=$ANDROID_NDK_PATH/platforms/android-5/arch-arm"
            ;;
        mips)
            endian="little"
            gccchoice="4.4.3"
            gcctarget="mipsel-linux-android-"
            thread_support="HAVE_SIGALTSTACK_THREADS"
            GCCOPTS="$GCCOPTS -march=mips32 -mtune=r4600 -mno-mips16 -mno-long-calls -fomit-frame-pointer \
                    --sysroot=$ANDROID_NDK_PATH/platforms/android-14/arch-mips -fPIC"
            LDOPTS="$LDOPTS --sysroot=$ANDROID_NDK_PATH/platforms/android-14/arch-mips"
            ;;
        x86)
            endian=little
            gccchoice="4.4.3"
            gcctarget="i686-linux-android-"
            gccdir=x86-$gccchoice
            thread_support="HAVE_SIGALTSTACK_THREADS"
            GCCOPTS="$GCCOPTS -Wa,--noexecstack -ffunction-sections -fomit-frame-pointer\
                    --sysroot=$ANDROID_NDK_PATH/platforms/android-9/arch-x86"
            LDOPTS="$LDOPTS --sysroot=$ANDROID_NDK_PATH/platforms/android-9/arch-x86"
            ;;
        *)
            echo "ERROR: androidcc(): Unknown target architecture"
            exit
            ;;
    esac
    echo "Application environment deemed $endian endian"
    if [ -z "$gccdir" ]; then
        gccdir=$gcctarget$gccchoice
    fi
    gccprefix=$ANDROID_NDK_PATH/toolchains/$gccdir/prebuilt/$buildhost-x86
    PATH=$PATH:$gccprefix/bin
    prefixtools $gcctarget
}

whichadvanced () {
  atype=`echo "$1" | cut -c 2-`
  ##################################################################
  # Prompt for specific developer options
  #
  if [ "$atype" ]; then
    interact=
  else
    interact=1
    echo ""
    printf "Enter your developer options (press only enter when done)\n\
(D)EBUG, (L)ogf, Boot(c)hart, (S)imulator, (P)rofiling, (V)oice, (W)in32 crosscompile,\n\
(T)est plugins, S(m)all C lib, Logf to Ser(i)al port:"
    if [ "$modelname" = "archosplayer" ]; then
      printf ", Use (A)TA poweroff"
    fi
    if [ "$t_model" = "ondio" ]; then
      printf ", (B)acklight MOD"
    fi
    if [ "$modelname" = "iaudiom5" ]; then
      printf ", (F)M radio MOD"
    fi
    if [ "$modelname" = "iriverh120" ]; then
      printf ", (R)TC MOD"
    fi
    echo ""
  fi

  cont=1
  while [ $cont = "1" ]; do

    if [ "$CI" ]; then
      option='$ADVBUILDTYPE'
    else
      option=`input`
    fi

    case $option in
      [Dd])
        if [ "yes" = "$profile" ]; then
          echo "Debug is incompatible with profiling"
        else
          echo "DEBUG build enabled"
          use_debug="yes"
        fi
        ;;
      [Ll])
        echo "logf() support enabled"
        logf="yes"
        ;;
      [Mm])
        echo "Using Rockbox' small C library"
        extradefines="$extradefines -DHAVE_ROCKBOX_C_LIBRARY"
        ;;
      [Tt])
        echo "Including test plugins"
        extradefines="$extradefines -DHAVE_TEST_PLUGINS"
        ;;
      [Cc])
        echo "bootchart enabled (logf also enabled)"
        bootchart="yes"
        logf="yes"
        ;;
      [Ii])
        echo "Logf to serial port enabled (logf also enabled)"
        logf="yes"
        logf_serial="yes"
        ;;
      [Ss])
        echo "Simulator build enabled"
        simulator="yes"
        ;;
      [Pp])
        if [ "yes" = "$use_debug" ]; then
          echo "Profiling is incompatible with debug"
        else
          echo "Profiling support is enabled"
          profile="yes"
        fi
        ;;
      [Vv])
        echo "Voice build selected"
        voice="yes"
        ;;
      [Aa])
        if [ "$modelname" = "archosplayer" ]; then
          have_ata_poweroff="#define HAVE_ATA_POWER_OFF"
          echo "ATA power off enabled"
        fi
        ;;
      [Bb])
        if [ "$t_model" = "ondio" ]; then
          have_backlight="#define HAVE_BACKLIGHT"
          echo "Backlight functions enabled"
        fi
        ;;
      [Ff])
        if [ "$modelname" = "iaudiom5" ]; then
          have_fmradio_in="#define HAVE_FMRADIO_IN"
          echo "FM radio functions enabled"
        fi
        ;;
      [Rr])
        if [ "$modelname" = "iriverh120" ]; then
          config_rtc="#define CONFIG_RTC RTC_DS1339_DS3231"
          have_rtc_alarm="#define HAVE_RTC_ALARM"
          echo "RTC functions enabled (DS1339/DS3231)"
        fi
        ;;
      [Ww])
        echo "Enabling Windows 32 cross-compiling"
        win32crosscompile="yes"
        ;;
      "") # Match enter press when finished with advanced options
        cont=0
        ;;
      *)
        echo "[ERROR] Option $option unsupported"
        ;;
    esac
    if [ "$interact" ]; then
      btype="$btype$option"
    else
      atype=`echo "$atype" | cut -c 2-`
      [ "$atype" ] || cont=0
    fi
  done
  echo "done"

  if [ "yes" = "$voice" ]; then
    # Ask about languages to build
    picklang
    voicelanguage=`whichlang`
    echo "Voice language set to $voicelanguage"

    # Configure encoder and TTS engine for each language
    for thislang in `echo $voicelanguage | sed 's/,/ /g'`; do
      voiceconfig "$thislang"
    done
  fi
  if [ "yes" = "$use_debug" ]; then
    debug="-DDEBUG"
    GCCOPTS="$GCCOPTS -g -DDEBUG"
  fi
  if [ "yes" = "$logf" ]; then
    use_logf="#define ROCKBOX_HAS_LOGF 1"
  fi
  if [ "yes" = "$logf_serial" ]; then
    use_logf_serial="#define LOGF_SERIAL 1"
  fi
  if [ "yes" = "$bootchart" ]; then
    use_bootchart="#define DO_BOOTCHART 1"
  fi
  if [ "yes" = "$simulator" ]; then
    debug="-DDEBUG"
    extradefines="$extradefines -DSIMULATOR"
    archosrom=""
    flash=""
  fi
  if [ "yes" = "$profile" ]; then
    extradefines="$extradefines -DRB_PROFILE"
    PROFILE_OPTS="-finstrument-functions"
  fi
}

# Configure voice settings
voiceconfig () {
    thislang=$1
    if [ ! "$ARG_TTS" ]; then
        echo "Building $thislang voice for $modelname. Select options"
        echo ""
    fi

    if [ -n "`findtool flite`" ]; then
        FLITE="F(l)ite "
        FLITE_OPTS=""
        DEFAULT_TTS="flite"
        DEFAULT_TTS_OPTS=$FLITE_OPTS
        DEFAULT_NOISEFLOOR="500"
        DEFAULT_CHOICE="l"
    fi
    if [ -n "`findtool espeak`" ]; then
        ESPEAK="(e)Speak "
        ESPEAK_OPTS=""
        DEFAULT_TTS="espeak"
        DEFAULT_TTS_OPTS=$ESPEAK_OPTS
        DEFAULT_NOISEFLOOR="500"
        DEFAULT_CHOICE="e"
    fi
    if [ -n "`findtool festival`" ]; then
        FESTIVAL="(F)estival "
        case "$thislang" in
            "italiano")
            FESTIVAL_OPTS="--language italian"
            ;;
            "espanol")
            FESTIVAL_OPTS="--language spanish"
            ;;
            "finnish")
            FESTIVAL_OPTS="--language finnish"
            ;;
            "czech")
            FESTIVAL_OPTS="--language czech"
            ;;
            *)
            FESTIVAL_OPTS=""
            ;;
        esac
        DEFAULT_TTS="festival"
        DEFAULT_TTS_OPTS=$FESTIVAL_OPTS
        DEFAULT_NOISEFLOOR="500"
        DEFAULT_CHOICE="f"
    fi
    if [ -n "`findtool swift`" ]; then
        SWIFT="S(w)ift "
        SWIFT_OPTS=""
        DEFAULT_TTS="swift"
        DEFAULT_TTS_OPTS=$SWIFT_OPTS
        DEFAULT_NOISEFLOOR="500"
        DEFAULT_CHOICE="w"
    fi
    # Allow SAPI if Windows is in use
    if [ -n "`findtool winver`" ]; then
        SAPI="(S)API "
        SAPI_OPTS=""
        DEFAULT_TTS="sapi"
        DEFAULT_TTS_OPTS=$SAPI_OPTS
        DEFAULT_NOISEFLOOR="500"
        DEFAULT_CHOICE="s"
    fi

    if [ "$FESTIVAL" = "$FLITE" ] && [ "$FLITE" = "$ESPEAK" ] && [ "$ESPEAK" = "$SAPI" ] && [ "$SAPI" = "$SWIFT" ]; then
        echo "You need Festival, eSpeak or Flite in your path, or SAPI available to build voice files"
        exit 3
    fi

    if [ "$ARG_TTS" ]; then
        option=$ARG_TTS
    else
        echo "TTS engine to use: ${FLITE}${FESTIVAL}${ESPEAK}${SAPI}${SWIFT}(${DEFAULT_CHOICE})?"
        option=`input`
        if [ -z "$option" ]; then option=${DEFAULT_CHOICE}; fi
        advopts="$advopts --tts=$option"
    fi
    case "$option" in
        [Ll])
        TTS_ENGINE="flite"
        NOISEFLOOR="500" # TODO: check this value
        TTS_OPTS=$FLITE_OPTS
        ;;
        [Ee])
        TTS_ENGINE="espeak"
        NOISEFLOOR="500"
        TTS_OPTS=$ESPEAK_OPTS
        ;;
        [Ff])
        TTS_ENGINE="festival"
        NOISEFLOOR="500"
        TTS_OPTS=$FESTIVAL_OPTS
        ;;
        [Ss])
        TTS_ENGINE="sapi"
        NOISEFLOOR="500"
        TTS_OPTS=$SAPI_OPTS
        ;;
    [Ww])
        TTS_ENGINE="swift"
        NOISEFLOOR="500"
        TTS_OPTS=$SWIFT_OPTS
	;;
        *)
        TTS_ENGINE=$DEFAULT_TTS
        TTS_OPTS=$DEFAULT_TTS_OPTS
        NOISEFLOOR=$DEFAULT_NOISEFLOOR
    esac
    echo "Using $TTS_ENGINE for TTS"

    # Select which voice to use for Festival
    if [ "$TTS_ENGINE" = "festival" ]; then
        voicelist=`echo "(voice.list)"|festival -i 2>/dev/null |tr "\n" " "|sed -e 's/.*festival> (\(.*\)) festival>/\1/'|sort`
        for voice in $voicelist; do
            TTS_FESTIVAL_VOICE="$voice" # Default choice
            break
        done
        if [ "$ARG_VOICE" ]; then
            CHOICE=$ARG_VOICE
        else
            i=1
            for voice in $voicelist; do
                printf "%3d. %s\n" "$i" "$voice"
                i=`expr $i + 1`
            done
            printf "Please select which Festival voice to use (default is $TTS_FESTIVAL_VOICE): "
            CHOICE=`input`
        fi
        i=1
        for voice in $voicelist; do
            if [ "$i" = "$CHOICE" -o "$voice" = "$CHOICE" ]; then
                TTS_FESTIVAL_VOICE="$voice"
            fi
            i=`expr $i + 1`
        done
        advopts="$advopts --voice=$CHOICE"
        echo "Festival voice set to $TTS_FESTIVAL_VOICE"
        echo "(voice_$TTS_FESTIVAL_VOICE)" > festival-prolog.scm
    fi

    # Read custom tts options from command line
    if [ "$ARG_TTSOPTS" ]; then
        TTS_OPTS="$ARG_TTSOPTS"
        echo "$TTS_ENGINE options set to $TTS_OPTS"
    fi

    if [ "$swcodec" = "yes" ]; then
        ENCODER="rbspeexenc"
        ENC_OPTS="-q 4 -c 10"
    else
        if [ -n "`findtool lame`" ]; then
            ENCODER="lame"
            ENC_OPTS="--resample 12 -t -m m -h -V 9.999 -S -B 64 --vbr-new"
         else
            echo "You need LAME in the system path to build voice files for"
            echo "HWCODEC targets."
            exit 4
         fi
    fi
 
    echo "Using $ENCODER for encoding voice clips"

    # Read custom encoder options from command line
    if [ "$ARG_ENCOPTS" ]; then
        ENC_OPTS="$ARG_ENCOPTS"
        echo "$ENCODER options set to $ENC_OPTS"
    fi

    TEMPDIR="${pwd}"
    if [ -n "`findtool cygpath`" ]; then
        TEMPDIR=`cygpath . -a -w`
    fi
}

picklang() {
    # figure out which languages that are around
    for file in $rootdir/apps/lang/*.lang; do
        clean=`basename $file .lang`
        langs="$langs $clean"
    done

    if [ "$ARG_LANG" ]; then
        pick=$ARG_LANG
    else
        echo "Select a number for the language to use (default is english)"
        # FIXME The multiple-language feature is currently broken
        # echo "You may enter a comma-separated list of languages to build"

        num=1
        for one in $langs; do
            echo "$num. $one"
            num=`expr $num + 1`
        done
        pick=`input`
        advopts="$advopts --language=$pick"
    fi
}

whichlang() {
    output=""
    # Allow the user to pass a comma-separated list of langauges
    for thispick in `echo $pick | sed 's/,/ /g'`; do
        num=1
        for one in $langs; do
            # Accept both the language number and name
            if [ "$num" = "$thispick" ] || [ "$thispick" = "$one" ]; then
                if [ "$output" = "" ]; then
                    output=$one
                else
                    output=$output,$one
                fi
            fi
            num=`expr $num + 1`
        done
    done
    if [ -z "$output" ]; then
      # pick a default
      output="english"
    fi
    echo $output
}

help() {
  echo "Rockbox configure script."
  echo "Invoke this in a directory to generate a Makefile to build Rockbox"
  echo "Do *NOT* run this within the tools directory!"
  echo ""
  cat <<EOF
  Usage: configure [OPTION]...
  Options:
    --target=TARGET   Sets the target, TARGET can be either the target ID or
                      corresponding string. Run without this option to see all
                      available targets.

    --ram=RAM         Sets the RAM for certain targets. Even though any number
                      is accepted, not every number is correct. The default
                      value will be applied, if you entered a wrong number
                      (which depends on the target). Watch the output.  Run
                      without this option if you are not sure which the right
                      number is.

    --type=TYPE       Sets the build type. Shortcuts are also valid.
                      Run without this option to see all available types.
                      Multiple values are allowed and managed in the input
                      order. So --type=b stands for Bootloader build, while
                      --type=ab stands for "Backlight MOD" build.

    --lcdwidth=X      Sets the width of the LCD. Used only for application
                      targets.

    --lcdheight=Y     Sets the height of the LCD. Used only for application
                      targets.

    --language=LANG   Set the language used for voice generation (used only if
                      TYPE is AV).

    --tts=ENGINE      Set the TTS engine used for voice generation (used only
                      if TYPE is AV).

    --voice=VOICE     Set voice to use with selected TTS (used only if TYPE is
                      AV).

    --ttsopts=OPTS    Set TTS engine manual options (used only if TYPE is AV).

    --encopts=OPTS    Set encoder manual options (used only if ATYPE is AV).

    --rbdir=dir       Use alternative rockbox directory (default: ${rbdir}).
                      This is useful for having multiple alternate builds on
                      your device that you can load with ROLO. However as the
                      bootloader looks for .rockbox you won't be able to boot
                      into this build.

    --ccache          Enable ccache use (done by default these days)
    --no-ccache       Disable ccache use

    --thumb           Build with -mthumb (for ARM builds)
    --no-thumb        The opposite of --thumb (don't use thumb even for targets
                      where this is the default
    --sdl-threads     Force use of SDL threads. They have inferior performance,
                      but are better debuggable with GDB
    --no-sdl-threads  Disallow use of SDL threads. This prevents the default
                      behavior of falling back to them if no native thread
                      support was found.
    --prefix          Target installation directory
    --help            Shows this message (must not be used with other options)

EOF

  exit
}

ARG_CCACHE=
ARG_ENCOPTS=
ARG_LANG=
ARG_RAM=
ARG_RBDIR=
ARG_TARGET=
ARG_TTS=
ARG_TTSOPTS=
ARG_TYPE=
ARG_VOICE=
ARG_ARM_THUMB=
ARG_PREFIX="$PREFIX"
ARG_THREAD_SUPPORT=
err=            
for arg in "$@"; do
	case "$arg" in
		--ccache)     ARG_CCACHE=1;;
		--no-ccache)  ARG_CCACHE=0;;
		--encopts=*)  ARG_ENCOPTS=`echo "$arg" | cut -d = -f 2`;;
		--language=*) ARG_LANG=`echo "$arg" | cut -d = -f 2`;;
		--lcdwidth=*) ARG_LCDWIDTH=`echo "$arg" | cut -d = -f 2`;;
		--lcdheight=*) ARG_LCDHEIGHT=`echo "$arg" | cut -d = -f 2`;;
		--ram=*)      ARG_RAM=`echo "$arg" | cut -d = -f 2`;;
		--rbdir=*)    ARG_RBDIR=`echo "$arg" | cut -d = -f 2`;;
		--target=*)   ARG_TARGET=`echo "$arg" | cut -d = -f 2`;;
		--tts=*)      ARG_TTS=`echo "$arg" | cut -d = -f 2`;;
		--ttsopts=*)  ARG_TTSOPTS=`echo "$arg" | cut -d = -f 2`;;
		--type=*)     ARG_TYPE=`echo "$arg" | cut -d = -f 2`;;
		--voice=*)    ARG_VOICE=`echo "$arg" | cut -d = -f 2`;;
		--thumb)      ARG_ARM_THUMB=1;;
		--no-thumb)   ARG_ARM_THUMB=0;;
        --sdl-threads)ARG_THREAD_SUPPORT=1;;
        --no-sdl-threads)
                      ARG_THREAD_SUPPORT=0;;
        --prefix=*)   ARG_PREFIX=`echo "$arg" | cut -d = -f 2`;;
		--help)       help;;
		*)            err=1; echo "[ERROR] Option '$arg' unsupported";;
	esac
done
[ "$err" ] && exit 1

advopts=

if [ "$TMPDIR" != "" ]; then
  tmpdir=$TMPDIR
else
  tmpdir=/tmp
fi
echo Using temporary directory $tmpdir

if test -r "configure"; then
 # this is a check for a configure script in the current directory, it there
 # is one, try to figure out if it is this one!

 if { grep "^#   Jukebox" configure >/dev/null 2>&1 ; } then
   echo "WEEEEEEEEP. Don't run this configure script within the tools directory."
   echo "It will only cause you pain and grief. Instead do this:"
   echo ""
   echo " cd .."
   echo " mkdir build-dir"
   echo " cd build-dir"
   echo " ../tools/configure"
   echo ""
   echo "Much happiness will arise from this. Enjoy"
   exit 5
 fi
fi

# get our current directory
pwd=`pwd`;

if { echo $pwd | grep " "; } then
  echo "You're running this script in a path that contains space. The build"
  echo "system is unfortunately not clever enough to deal with this. Please"
  echo "run the script from a different path, rename the path or fix the build"
  echo "system!"
  exit 6
fi

if [ -z "$rootdir" ]; then
  ##################################################################
  # Figure out where the source code root is!
  #
  rootdir=`dirname $0`/../

  #####################################################################
  # Convert the possibly relative directory name to an absolute version
  #
  now=`pwd`
  cd $rootdir
  rootdir=`pwd`

  # cd back to the build dir
  cd $now
fi

apps="apps"
appsdir='$(ROOTDIR)/apps'
toolsdir='$(ROOTDIR)/tools'


##################################################################
# Figure out target platform
#

if [ "$CI" ]; then
  buildfor=$BUILDFOR
else
  echo "Enter target platform:"
cat <<EOF
 ==Archos==               ==iriver==             ==Apple iPod==
  0) Player/Studio        10) H120/H140          20) Color/Photo
  1) Recorder             11) H320/H340          21) Nano 1G
  2) FM Recorder          12) iHP-100/110/115    22) Video
  3) Recorder v2          13) iFP-790            23) 3G
  4) Ondio SP             14) H10 20Gb           24) 4G Grayscale
  5) Ondio FM             15) H10 5/6Gb          25) Mini 1G
  6) AV300                                       26) Mini 2G
                          ==Toshiba==            27) 1G, 2G
 ==Cowon/iAudio==         40) Gigabeat F/X       28) Nano 2G
 30) X5/X5V/X5L           41) Gigabeat S         29) Classic/6G
 31) M5/M5L
 32) 7                    ==Olympus=             ==SanDisk==
 33) D2                   70) M:Robe 500         50) Sansa e200
 34) M3/M3L               71) M:Robe 100         51) Sansa e200R
                                                 52) Sansa c200
 ==Creative==             ==Philips==            53) Sansa m200
 90) Zen Vision:M 30GB    100) GoGear SA9200     54) Sansa c100
 91) Zen Vision:M 60GB    101) GoGear HDD1630/   55) Sansa Clip
 92) Zen Vision                HDD1830           56) Sansa e200v2
 93) Zen X-Fi2            102) GoGear HDD6330    57) Sansa m200v4
 94) Zen X-Fi3                                   58) Sansa Fuze
                          ==Meizu==              59) Sansa c200v2
 ==Onda==                 110) M6SL              60) Sansa Clipv2
 120) VX747               111) M6SP              61) Sansa View
 121) VX767               112) M3                62) Sansa Clip+
 122) VX747+                                     63) Sansa Fuze v2
 123) VX777               ==Tatung==             64) Sansa Fuze+
                          150) Elio TPJ-1022     65) Sansa Clip Zip
 ==Samsung==                                     66) Sansa Connect
 140) YH-820              ==Packard Bell==
 141) YH-920              160) Vibe 500          ==Logik==
 142) YH-925                                     80) DAX 1GB MP3/DAB
 143) YP-S3               ==MPIO==
                          170) HD200             ==Lyre project==
 ==Application==          171) HD300             130) Lyre proto 1
 200) SDL                                        131) Mini2440
 201) Android             ==ROCKCHIP==
 202) Nokia N8xx          180) rk27xx generic    ==HiFiMAN==
 203) Nokia N900                                 190) HM-60x
 204) Pandora                                    191) HM-801
 205) Samsung YP-R0
 206) Android MIPS
 207) Android x86
EOF

  buildfor=`input`;

fi
  # Set of tools built for all target platforms:
  toolset="rdf2binary convbdf codepages"

  # Toolsets for some target families:
  archosbitmaptools="$toolset scramble descramble sh2d uclpack bmp2rb"
  iriverbitmaptools="$toolset scramble descramble mkboot bmp2rb"
  iaudiobitmaptools="$toolset scramble descramble mkboot bmp2rb"
  ipodbitmaptools="$toolset scramble bmp2rb"
  gigabeatbitmaptools="$toolset scramble descramble bmp2rb"
  tccbitmaptools="$toolset scramble bmp2rb"
  # generic is used by IFP, Meizu and Onda
  genericbitmaptools="$toolset bmp2rb"
  # scramble is used by all other targets
  scramblebitmaptools="$genericbitmaptools scramble"


  #  ---- For each target ----
  #
  #   *Variables*
  # target_id: a unique number identifying this target, IS NOT the menu number.
  #            Just use the currently highest number+1 when you add a new
  #            target.
  # modelname: short model name used all over to identify this target
  # memory:    number of megabytes of RAM this target has. If the amount can
  #            be selected by the size prompt, let memory be unset here
  # target:    -Ddefine passed to the build commands to make the correct
  #            config-*.h file get included etc
  # tool:      the tool that takes a plain binary and converts that into a
  #            working "firmware" file for your target
  # output:    the final output file name
  # boottool:  the tool that takes a plain binary and generates a bootloader
  #            file for your target (or blank to use $tool)
  # bootoutput:the final output file name for the bootloader (or blank to use
  #            $output)
  # appextra:  passed to the APPEXTRA variable in the Makefiles.
  #            TODO: add proper explanation
  # archosrom: used only for Archos targets that build a special flashable .ucl
  #            image.
  # flash:     name of output for flashing, for targets where there's a special
  #            file output for this.
  # plugins:   set to 'yes' to build the plugins. Early development builds can
  #            set this to no in the early stages to have an easier life for a
  #            while
  # swcodec:   set 'yes' on swcodec targets
  # toolset:   lists what particular tools in the tools/ directory that this
  #            target needs to have built prior to building Rockbox
  #
  #   *Functions*
  # *cc:       sets up gcc and compiler options for your target builds. Note
  #            that if you select a simulator build, the compiler selection is
  #            overridden later in the script.

  case $buildfor in

   0|archosplayer)
    target_id=1
    modelname="archosplayer"
    target="ARCHOS_PLAYER"
    shcc
    tool="$rootdir/tools/scramble"
    output="archos.mod"
    appextra="player:gui"
    archosrom="$pwd/rombox.ucl"
    flash="$pwd/rockbox.ucl"
    plugins="yes"
    swcodec=""

    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$toolset scramble descramble sh2d player_unifont uclpack"

    # Note: the convbdf is present in the toolset just because: 1) the
    # firmware/Makefile assumes it is present always, and 2) we will need it when we
    # build the player simulator

    t_cpu="sh"
    t_manufacturer="archos"
    t_model="player"
    ;;

   1|archosrecorder)
    target_id=2
    modelname="archosrecorder"
    target="ARCHOS_RECORDER"
    shcc
    tool="$rootdir/tools/scramble"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 0"
    output="ajbrec.ajz"
    appextra="recorder:gui:radio"
    #archosrom="$pwd/rombox.ucl"
    flash="$pwd/rockbox.ucl"
    plugins="yes"
    swcodec=""
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$archosbitmaptools
    t_cpu="sh"
    t_manufacturer="archos"
    t_model="recorder"
    ;;

   2|archosfmrecorder)
    target_id=3
    modelname="archosfmrecorder"
    target="ARCHOS_FMRECORDER"
    shcc
    tool="$rootdir/tools/scramble -fm"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 0"
    output="ajbrec.ajz"
    appextra="recorder:gui:radio"
    #archosrom="$pwd/rombox.ucl"
    flash="$pwd/rockbox.ucl"
    plugins="yes"
    swcodec=""
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$archosbitmaptools
    t_cpu="sh"
    t_manufacturer="archos"
    t_model="fm_v2"
    ;;

   3|archosrecorderv2)
    target_id=4
    modelname="archosrecorderv2"
    target="ARCHOS_RECORDERV2"
    shcc
    tool="$rootdir/tools/scramble -v2"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 0"
    output="ajbrec.ajz"
    appextra="recorder:gui:radio"
    #archosrom="$pwd/rombox.ucl"
    flash="$pwd/rockbox.ucl"
    plugins="yes"
    swcodec=""
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$archosbitmaptools
    t_cpu="sh"
    t_manufacturer="archos"
    t_model="fm_v2"
    ;;

   4|archosondiosp)
    target_id=7
    modelname="archosondiosp"
    target="ARCHOS_ONDIOSP"
    shcc
    tool="$rootdir/tools/scramble -osp"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 0"
    output="ajbrec.ajz"
    appextra="recorder:gui:radio"
    #archosrom="$pwd/rombox.ucl"
    flash="$pwd/rockbox.ucl"
    plugins="yes"
    swcodec=""
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$archosbitmaptools
    t_cpu="sh"
    t_manufacturer="archos"
    t_model="ondio"
    ;;

   5|archosondiofm)
    target_id=8
    modelname="archosondiofm"
    target="ARCHOS_ONDIOFM"
    shcc
    tool="$rootdir/tools/scramble -ofm"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 0"
    output="ajbrec.ajz"
    appextra="recorder:gui:radio"
    #archosrom="$pwd/rombox.ucl"
    flash="$pwd/rockbox.ucl"
    plugins="yes"
    swcodec=""
    toolset=$archosbitmaptools
    t_cpu="sh"
    t_manufacturer="archos"
    t_model="ondio"
    ;;

   6|archosav300)
    target_id=38
    modelname="archosav300"
    target="ARCHOS_AV300"
    memory=16 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -mm=C"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 6"
    output="cjbm.ajz"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec=""
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$toolset scramble descramble bmp2rb"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="archos"
    t_model="av300"
    ;;

  10|iriverh120)
    target_id=9
    modelname="iriverh120"
    target="IRIVER_H120"
    memory=32 # always
    coldfirecc
    tool="$rootdir/tools/scramble -add=h120"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 2"
    bmp2rb_remotemono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_remotenative="$rootdir/tools/bmp2rb -f 0"
    output="rockbox.iriver"
    bootoutput="bootloader.iriver"
    appextra="recorder:gui:radio"
    flash="$pwd/rombox.iriver"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$iriverbitmaptools
    t_cpu="coldfire"
    t_manufacturer="iriver"
    t_model="h100"
    ;;

   11|iriverh300)
    target_id=10
    modelname="iriverh300"
    target="IRIVER_H300"
    memory=32 # always
    coldfirecc
    tool="$rootdir/tools/scramble -add=h300"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    bmp2rb_remotemono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_remotenative="$rootdir/tools/bmp2rb -f 0"
    output="rockbox.iriver"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$iriverbitmaptools
    t_cpu="coldfire"
    t_manufacturer="iriver"
    t_model="h300"
    ;;

   12|iriverh100)
    target_id=11
    modelname="iriverh100"
    target="IRIVER_H100"
    memory=16 # always
    coldfirecc
    tool="$rootdir/tools/scramble -add=h100"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 2"
    bmp2rb_remotemono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_remotenative="$rootdir/tools/bmp2rb -f 0"
    output="rockbox.iriver"
    bootoutput="bootloader.iriver"
    appextra="recorder:gui:radio"
    flash="$pwd/rombox.iriver"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$iriverbitmaptools
    t_cpu="coldfire"
    t_manufacturer="iriver"
    t_model="h100"
    ;;

   13|iriverifp7xx)
    target_id=19
    modelname="iriverifp7xx"
    target="IRIVER_IFP7XX"
    memory=1
    arm7tdmicc short
    tool="cp"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 0"
    output="rockbox.wma"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$genericbitmaptools
    t_cpu="arm"
    t_manufacturer="pnx0101"
    t_model="iriver-ifp7xx"
    ;;

   14|iriverh10)
    target_id=22
    modelname="iriverh10"
    target="IRIVER_H10"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v3 -model=h10 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 5"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v3 -model=h10 -type=RBBL"
    bootoutput="H10_20GC.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="iriver"
    t_model="h10"
    ;;

   15|iriverh10_5gb)
    target_id=24
    modelname="iriverh10_5gb"
    target="IRIVER_H10_5GB"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v2 -model=h105 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 5"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v2 -model=h105 -type=RBBL"
    bootoutput="H10.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="iriver"
    t_model="h10"
    ;;

   20|ipodcolor)
    target_id=13
    modelname="ipodcolor"
    target="IPOD_COLOR"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -add=ipco"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 5"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="ipod"
    t_model="color"
    ;;

   21|ipodnano1g)
    target_id=14
    modelname="ipodnano1g"
    target="IPOD_NANO"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -add=nano"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 5"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="ipod"
    t_model="nano"
    ;;

   22|ipodvideo)
    target_id=15
    modelname="ipodvideo"
    target="IPOD_VIDEO"
    memory=64 # always. This is reduced at runtime if needed
    arm7tdmicc
    tool="$rootdir/tools/scramble -add=ipvd"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="ipod"
    t_model="video"
    ;;

   23|ipod3g)
    target_id=16
    modelname="ipod3g"
    target="IPOD_3G"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -add=ip3g"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 6"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="ipod"
    t_model="3g"
    ;;

   24|ipod4g)
    target_id=17
    modelname="ipod4g"
    target="IPOD_4G"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -add=ip4g"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 6"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="ipod"
    t_model="4g"
    ;;

   25|ipodmini1g)
    target_id=18
    modelname="ipodmini1g"
    target="IPOD_MINI"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -add=mini"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 6"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="ipod"
    t_model="mini"
    ;;

   26|ipodmini2g)
    target_id=21
    modelname="ipodmini2g"
    target="IPOD_MINI2G"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -add=mn2g"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 6"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="ipod"
    t_model="mini2g"
    ;;

   27|ipod1g2g)
    target_id=29
    modelname="ipod1g2g"
    target="IPOD_1G2G"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -add=1g2g"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 6"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="ipod"
    t_model="1g2g"
    ;;

   28|ipodnano2g)
    target_id=62
    modelname="ipodnano2g"
    target="IPOD_NANO2G"
    memory=32 # always
    arm940tcc
    tool="$rootdir/tools/scramble -add=nn2g"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="s5l8700"
    t_model="ipodnano2g"
    ;;

   29|ipod6g)
    target_id=71
    modelname="ipod6g"
    target="IPOD_6G"
    memory=64 # always
    arm926ejscc
    tool="$rootdir/tools/scramble -add=ip6g"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.ipod"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="bootloader-$modelname.ipod"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$ipodbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="s5l8702"
    t_model="ipod6g"
    ;;

   30|iaudiox5)
    target_id=12
    modelname="iaudiox5"
    target="IAUDIO_X5"
    memory=16 # always
    coldfirecc
    tool="$rootdir/tools/scramble -add=iax5"
    boottool="$rootdir/tools/scramble -iaudiox5"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    bmp2rb_remotemono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_remotenative="$rootdir/tools/bmp2rb -f 7"
    output="rockbox.iaudio"
    bootoutput="x5_fw.bin"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$iaudiobitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="coldfire"
    t_manufacturer="iaudio"
    t_model="x5"
    ;;

   31|iaudiom5)
    target_id=28
    modelname="iaudiom5"
    target="IAUDIO_M5"
    memory=16 # always
    coldfirecc
    tool="$rootdir/tools/scramble -add=iam5"
    boottool="$rootdir/tools/scramble -iaudiom5"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 2"
    bmp2rb_remotemono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_remotenative="$rootdir/tools/bmp2rb -f 7"
    output="rockbox.iaudio"
    bootoutput="m5_fw.bin"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$iaudiobitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="coldfire"
    t_manufacturer="iaudio"
    t_model="m5"
    ;;

   32|iaudio7)
    target_id=32
    modelname="iaudio7"
    target="IAUDIO_7"
    memory=16 # always
    arm946cc
    tool="$rootdir/tools/scramble -add=i7"
    boottool="$rootdir/tools/scramble -tcc=crc"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.iaudio"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    bootoutput="I7_FW.BIN"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$tccbitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="tcc77x"
    t_model="iaudio7"
    ;;

    33|cowond2)
    target_id=34
    modelname="cowond2"
    target="COWON_D2"
    memory=32
    arm926ejscc
    tool="$rootdir/tools/scramble -add=d2"
    boottool="cp "
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.d2"
    bootoutput="bootloader-cowond2.bin"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset="$tccbitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="tcc780x"
    t_model="cowond2"
    ;;
    
   34|iaudiom3)
    target_id=37
    modelname="iaudiom3"
    target="IAUDIO_M3"
    memory=16 # always
    coldfirecc
    tool="$rootdir/tools/scramble -add=iam3"
    boottool="$rootdir/tools/scramble -iaudiom3"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 7"
    output="rockbox.iaudio"
    bootoutput="cowon_m3.bin"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$iaudiobitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="coldfire"
    t_manufacturer="iaudio"
    t_model="m3"
    ;;

   40|gigabeatfx)
    target_id=20
    modelname="gigabeatfx"
    target="GIGABEAT_F"
    memory=32 # always
    arm9tdmicc
    tool="$rootdir/tools/scramble -add=giga"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.gigabeat"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$gigabeatbitmaptools
    boottool="$rootdir/tools/scramble -gigabeat"
    bootoutput="FWIMG01.DAT"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="s3c2440"
    t_model="gigabeat-fx"
    ;;

    41|gigabeats)
    target_id=26
    modelname="gigabeats"
    target="GIGABEAT_S"
    memory=64
    arm1136jfscc
    tool="$rootdir/tools/scramble -add=gigs"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.gigabeat"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset="$gigabeatbitmaptools"
    boottool="$rootdir/tools/scramble -gigabeats"
    bootoutput="nk.bin"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="imx31"
    t_model="gigabeat-s"
    ;;

    70|mrobe500)
    target_id=36
    modelname="mrobe500"
    target="MROBE_500"
    memory=64 # always
    arm926ejscc
    tool="$rootdir/tools/scramble -add=m500"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 8"
    bmp2rb_remotemono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_remotenative="$rootdir/tools/bmp2rb -f 0"
    output="rockbox.mrobe500"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$gigabeatbitmaptools
    boottool="cp "
    bootoutput="rockbox.mrboot"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="tms320dm320"
    t_model="mrobe-500"
    ;;

   71|mrobe100)
    target_id=33
    modelname="mrobe100"
    target="MROBE_100"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v2 -model=m100 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_remotemono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_remotenative="$rootdir/tools/bmp2rb -f 0"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v2 -model=m100 -type=RBBL"
    bootoutput="pp5020.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="olympus"
    t_model="mrobe-100"
    ;;

   80|logikdax)
    target_id=31
    modelname="logikdax"
    target="LOGIK_DAX"
    memory=2 # always
    arm946cc
    tool="$rootdir/tools/scramble -add=ldax"
    boottool="$rootdir/tools/scramble -tcc=crc"
    bootoutput="player.rom"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 0"
    output="rockbox.logik"
    appextra="recorder:gui:radio"
    plugins=""
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$tccbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="tcc77x"
    t_model="logikdax"
    ;;
	
    90|zenvisionm30gb)
    target_id=35
    modelname="zenvisionm30gb"
    target="CREATIVE_ZVM"
    memory=64
    arm926ejscc
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -creative=zvm"
    USE_ELF="yes"
    output="rockbox.zvm"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$ipodbitmaptools
    boottool="$rootdir/tools/scramble -creative=zvm -no-ciff"
    bootoutput="rockbox.zvmboot"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="tms320dm320"
    t_model="creative-zvm"
    ;;
    
    91|zenvisionm60gb)
    target_id=40
    modelname="zenvisionm60gb"
    target="CREATIVE_ZVM60GB"
    memory=64
    arm926ejscc
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -creative=zvm60 -no-ciff"
    USE_ELF="yes"
    output="rockbox.zvm60"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$ipodbitmaptools
    boottool="$rootdir/tools/scramble -creative=zvm60"
    bootoutput="rockbox.zvm60boot"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="tms320dm320"
    t_model="creative-zvm"
    ;;
    
    92|zenvision)
    target_id=39
    modelname="zenvision"
    target="CREATIVE_ZV"
    memory=64
    arm926ejscc
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -creative=zenvision -no-ciff"
    USE_ELF="yes"
    output="rockbox.zv"
    appextra="recorder:gui:radio"
    plugins=""
    swcodec="yes"
    toolset=$ipodbitmaptools
    boottool="$rootdir/tools/scramble -creative=zenvision"
    bootoutput="rockbox.zvboot"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="tms320dm320"
    t_model="creative-zvm"
    ;;

   93|creativezenxfi2)
    target_id=80
    modelname="creativezenxfi2"
    target="CREATIVE_ZENXFI2"
    memory=64
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -add=zxf2"
    output="rockbox.creative"
    bootoutput="bootloader-zenxfi2.creative"
    appextra="gui:recorder:radio"
    plugins=""
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="imx233"
    t_model="creative-zenxfi2"
    arm926ejscc
    ;;

   94|creativezenxfi3)
    target_id=81
    modelname="creativezenxfi3"
    target="CREATIVE_ZENXFI3"
    memory=64
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -add=zxf3"
    output="rockbox.creative"
    bootoutput="bootloader-zenxfi3.creative"
    appextra="gui:recorder:radio"
    plugins=""
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="imx233"
    t_model="creative-zenxfi3"
    arm926ejscc
    ;;

   50|sansae200)
    target_id=23
    modelname="sansae200"
    target="SANSA_E200"
    memory=32 # supposedly
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v3 -model=e200 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v3 -model=e200 -type=RBBL"
    bootoutput="PP5022.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="sandisk"
    t_model="sansa-e200"
    ;;

   51|sansae200r)
    # the e200R model is pretty much identical to the e200, it only has a
    # different option to the scramble tool when building a bootloader and
    # makes the bootloader output file name in all lower case.
    target_id=27
    modelname="sansae200r"
    target="SANSA_E200"
    memory=32 # supposedly
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v3 -model=e20r -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4r -model=e20r -type=RBBL"
    bootoutput="pp5022.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="sandisk"
    t_model="sansa-e200"
    ;;

   52|sansac200)
    target_id=30
    modelname="sansac200"
    target="SANSA_C200"
    memory=32 # supposedly
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v3 -model=c200 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v3 -model=c200 -type=RBBL"
    bootoutput="firmware.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="sandisk"
    t_model="sansa-c200"
    ;;

   53|sansam200)
    target_id=48
    modelname="sansam200"
    target="SANSA_M200"
    memory=1 # always
    arm946cc
    tool="$rootdir/tools/scramble -add=m200"
    boottool="$rootdir/tools/scramble -tcc=crc"
    bootoutput="player.rom"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 0"
    output="rockbox.m200"
    appextra="recorder:gui:radio"
    plugins=""
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$tccbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="tcc77x"
    t_model="m200"
    ;;

   54|sansac100)
    target_id=42 
    modelname="sansac100" 
    target="SANSA_C100"     
    memory=2
    arm946cc
    tool="$rootdir/tools/scramble -add=c100"
    boottool="$rootdir/tools/scramble -tcc=crc"
    bootoutput="player.rom"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.c100"
    appextra="recorder:gui:radio"
    plugins=""
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$tccbitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="tcc77x"
    t_model="c100"
    ;;

   55|sansaclip)
    target_id=50
    modelname="sansaclip"
    target="SANSA_CLIP"
    memory=2
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$bmp2rb_mono"
    tool="$rootdir/tools/scramble -add=clip"
    output="rockbox.sansa"
    bootoutput="bootloader-clip.sansa"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="as3525"
    t_model="sansa-clip"
    if [ "$ARG_ARM_THUMB" != 0 ]; then ARG_ARM_THUMB=1; fi
    arm9tdmicc
    GCCOPTS=`echo $GCCOPTS | sed 's/ -O / -Os /'`
    ;;


   56|sansae200v2)
    target_id=51
    modelname="sansae200v2"
    target="SANSA_E200V2"
    memory=8
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -add=e2v2"
    output="rockbox.sansa"
    bootoutput="bootloader-e200v2.sansa"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="as3525"
    t_model="sansa-e200v2"
    arm9tdmicc
    ;;


   57|sansam200v4)
    target_id=52
    modelname="sansam200v4"
    target="SANSA_M200V4"
    memory=2
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$bmp2rb_mono"
    tool="$rootdir/tools/scramble -add=m2v4"
    output="rockbox.sansa"
    bootoutput="bootloader-m200v4.sansa"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="as3525"
    t_model="sansa-m200v4"
    if [ "$ARG_ARM_THUMB" != 0 ]; then ARG_ARM_THUMB=1; fi
    arm9tdmicc
    GCCOPTS=`echo $GCCOPTS | sed 's/ -O / -Os /'`
    ;;


   58|sansafuze)
    target_id=53
    modelname="sansafuze"
    target="SANSA_FUZE"
    memory=8
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -add=fuze"
    output="rockbox.sansa"
    bootoutput="bootloader-fuze.sansa"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="as3525"
    t_model="sansa-fuze"
    arm9tdmicc
    ;;


   59|sansac200v2)
    target_id=55
    modelname="sansac200v2"
    target="SANSA_C200V2"
    memory=2 # as per OF diagnosis mode
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -add=c2v2"
    output="rockbox.sansa"
    bootoutput="bootloader-c200v2.sansa"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="as3525"
    t_model="sansa-c200v2"
    if [ "$ARG_ARM_THUMB" != 0 ]; then ARG_ARM_THUMB=1; fi
    arm9tdmicc
    GCCOPTS=`echo $GCCOPTS | sed 's/ -O / -Os /'`
    ;;

   60|sansaclipv2)
    target_id=60
    modelname="sansaclipv2"
    target="SANSA_CLIPV2"
    memory=8
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$bmp2rb_mono"
    tool="$rootdir/tools/scramble -add=clv2"
    output="rockbox.sansa"
    bootoutput="bootloader-clipv2.sansa"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="as3525"
    t_model="sansa-clipv2"
    arm926ejscc
    ;;

   61|sansaview)
    echo "Sansa View is not yet supported!"
    exit 1
    target_id=63
    modelname="sansaview"
    target="SANSA_VIEW"
    memory=32
    arm1176jzscc
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.mi4"
    appextra="gui"
    plugins=""
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v3 -model=view -type=RBBL"
    bootoutput="firmware.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="sandisk"
    t_model="sansa-view"
    ;;

   62|sansaclipplus)
    target_id=66
    modelname="sansaclipplus"
    target="SANSA_CLIPPLUS"
    memory=8
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$bmp2rb_mono"
    tool="$rootdir/tools/scramble -add=cli+"
    output="rockbox.sansa"
    bootoutput="bootloader-clipplus.sansa"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="as3525"
    t_model="sansa-clipplus"
    arm926ejscc
    ;;

   63|sansafuzev2)
    target_id=68
    modelname="sansafuzev2"
    target="SANSA_FUZEV2"
    memory=8 # not sure
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 5"
    tool="$rootdir/tools/scramble -add=fuz2"
    output="rockbox.sansa"
    bootoutput="bootloader-fuzev2.sansa"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="as3525"
    t_model="sansa-fuzev2"
    arm926ejscc
    ;;

   64|sansafuzeplus)
    target_id=80
    modelname="sansafuzeplus"
    target="SANSA_FUZEPLUS"
    memory=64
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -add=fuz+"
    output="rockbox.sansa"
    bootoutput="bootloader-fuzeplus.sansa"
    appextra="gui:recorder:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="imx233"
    t_model="sansa-fuzeplus"
    arm926ejscc
    ;;

   65|sansaclipzip)
    target_id=68
    modelname="sansaclipzip"
    target="SANSA_CLIPZIP"
    memory=8 # not sure
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -add=clzp"
    output="rockbox.sansa"
    bootoutput="bootloader-clipzip.sansa"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="as3525"
    t_model="sansa-clipzip"
    arm926ejscc
    ;;

   66|sansaconnect)
    target_id=81
    modelname="sansaconnect"
    target="SANSA_CONNECT"
    memory=64
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    tool="$rootdir/tools/scramble -add=conn"
    output="rockbox.sansa"
    bootoutput="bootloader-connect.sansa"
    appextra="recorder:gui"
    plugins="yes"
    swcodec="yes"
    toolset=$scramblebitmaptools
    t_cpu="arm"
    t_manufacturer="tms320dm320"
    t_model="sansa-connect"
    arm926ejscc
    ;;

   150|tatungtpj1022)
    target_id=25
    modelname="tatungtpj1022"
    target="TATUNG_TPJ1022"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -add tpj2"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 5"
    output="rockbox.elio"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v2"
    bootoutput="pp5020.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="tatung"
    t_model="tpj1022"
    ;;

   100|gogearsa9200)
    target_id=41
    modelname="gogearsa9200"
    target="PHILIPS_SA9200"
    memory=32 # supposedly
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v3 -model=9200 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v3 -model=9200 -type=RBBL"
    bootoutput="FWImage.ebn"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="philips"
    t_model="sa9200"
    ;;

   101|gogearhdd1630)
    target_id=43
    modelname="gogearhdd1630"
    target="PHILIPS_HDD1630"
    memory=32 # supposedly
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v3 -model=1630 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v3 -model=1630 -type=RBBL"
    bootoutput="FWImage.ebn"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="philips"
    t_model="hdd1630"
    ;;

   102|gogearhdd6330)
    target_id=65
    modelname="gogearhdd6330"
    target="PHILIPS_HDD6330"
    memory=64 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v3 -model=6330 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 5"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v3 -model=6330 -type=RBBL"
    bootoutput="FWImage.ebn"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="philips"
    t_model="hdd6330"
    ;;

   110|meizum6sl)
    target_id=49
    modelname="meizum6sl"
    target="MEIZU_M6SL"
    memory=16 # always
    arm940tbecc
    tool="cp"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.meizu"
    appextra="recorder:gui:radio"
    plugins="no" #FIXME
    swcodec="yes"
    toolset=$genericbitmaptools
    boottool="cp"
    bootoutput="rockboot.ebn"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="s5l8700"
    t_model="meizu-m6sl"
    ;;
    
   111|meizum6sp)
    target_id=46
    modelname="meizum6sp"
    target="MEIZU_M6SP"
    memory=16 # always
    arm940tbecc
    tool="cp"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.meizu"
    appextra="recorder:gui:radio"
    plugins="no" #FIXME
    swcodec="yes"
    toolset=$genericbitmaptools
    boottool="cp"
    bootoutput="rockboot.ebn"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="s5l8700"
    t_model="meizu-m6sp"
    ;;
    
   112|meizum3)
    target_id=47
    modelname="meizum3"
    target="MEIZU_M3"
    memory=16 # always
    arm940tbecc
    tool="cp"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.meizu"
    appextra="recorder:gui:radio"
    plugins="no" #FIXME
    swcodec="yes"
    toolset=$genericbitmaptools
    boottool="cp"
    bootoutput="rockboot.ebn"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="s5l8700"
    t_model="meizu-m3"
    ;;
    
    120|ondavx747)
    target_id=45
    modelname="ondavx747"
    target="ONDA_VX747"
    memory=16
    mipselcc
    tool="$rootdir/tools/scramble -add=x747"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.vx747"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$genericbitmaptools
    boottool="$rootdir/tools/scramble -ccpmp"
    bootoutput="ccpmp.bin"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="mips"
    t_manufacturer="ingenic_jz47xx"
    t_model="onda_vx747"
    ;;
    
    121|ondavx767)
    target_id=64
    modelname="ondavx767"
    target="ONDA_VX767"
    memory=16 #FIXME
    mipselcc
    tool="cp"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.vx767"
    appextra="recorder:gui:radio"
    plugins="" #FIXME
    swcodec="yes"
    toolset=$genericbitmaptools
    boottool="$rootdir/tools/scramble -ccpmp"
    bootoutput="ccpmp.bin"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="mips"
    t_manufacturer="ingenic_jz47xx"
    t_model="onda_vx767"
    ;;
    
    122|ondavx747p)
    target_id=54
    modelname="ondavx747p"
    target="ONDA_VX747P"
    memory=16
    mipselcc
    tool="$rootdir/tools/scramble -add=747p"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.vx747p"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$genericbitmaptools
    boottool="$rootdir/tools/scramble -ccpmp"
    bootoutput="ccpmp.bin"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="mips"
    t_manufacturer="ingenic_jz47xx"
    t_model="onda_vx747"
    ;;
    
    123|ondavx777)
    target_id=61
    modelname="ondavx777"
    target="ONDA_VX777"
    memory=16
    mipselcc
    tool="$rootdir/tools/scramble -add=x777"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.vx777"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    toolset=$genericbitmaptools
    boottool="$rootdir/tools/scramble -ccpmp"
    bootoutput="ccpmp.bin"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="mips"
    t_manufacturer="ingenic_jz47xx"
    t_model="onda_vx747"
    ;;
    
    130|lyreproto1)
    target_id=56
    modelname="lyreproto1"
    target="LYRE_PROTO1"
    memory=64
    arm926ejscc
    tool="cp"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.lyre"
    appextra="recorder:gui:radio"
    plugins=""
    swcodec="yes"
    toolset=$scramblebitmaptools
    boottool="cp"
    bootoutput="bootloader-proto1.lyre"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="at91sam"
    t_model="lyre_proto1"
    ;;
    
   131|mini2440)
    target_id=99
    modelname="mini2440"
    target="MINI2440"
    memory=64
    arm9tdmicc
    tool="$rootdir/tools/scramble -add=m244"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.mini2440"
    appextra="recorder:gui:radio"
    plugins=""
    swcodec="yes"
    toolset=$scramblebitmaptools
    boottool="cp"
    bootoutput="bootloader-mini2440.lyre"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="s3c2440"
    t_model="mini2440"
    ;;

   140|samsungyh820)
    target_id=57
    modelname="samsungyh820"
    target="SAMSUNG_YH820"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v2 -model=y820 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v2 -model=y820 -type=RBBL"
    bootoutput="FW_YH820.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="samsung"
    t_model="yh820"
    ;;

   141|samsungyh920)
    target_id=58
    modelname="samsungyh920"
    target="SAMSUNG_YH920"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v2 -model=y920 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 2"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v2 -model=y920 -type=RBBL"
    bootoutput="PP5020.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="samsung"
    t_model="yh920"
    ;;

   142|samsungyh925)
    target_id=59
    modelname="samsungyh925"
    target="SAMSUNG_YH925"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v2 -model=y925 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v2 -model=y925 -type=RBBL"
    bootoutput="FW_YH925.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="samsung"
    t_model="yh925"
    ;;

   143|samsungyps3)
    target_id=72
    modelname="samsungyps3"
    target="SAMSUNG_YPS3"
    memory=16 # always
    arm940tbecc
    tool="cp"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.yps3"
    appextra="recorder:gui:radio"
    plugins="no" #FIXME
    swcodec="yes"
    toolset=$genericbitmaptools
    boottool="cp"
    bootoutput="rockboot.ebn"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="s5l8700"
    t_model="yps3"
    ;;
    
   160|vibe500)
    target_id=67
    modelname="vibe500"
    target="PBELL_VIBE500"
    memory=32 # always
    arm7tdmicc
    tool="$rootdir/tools/scramble -mi4v3 -model=v500 -type=RBOS"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 5"
    output="rockbox.mi4"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    boottool="$rootdir/tools/scramble -mi4v3 -model=v500 -type=RBBL"
    bootoutput="jukebox.mi4"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset=$scramblebitmaptools
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_soc="pp"
    t_manufacturer="pbell"
    t_model="vibe500"
    ;;

   170|mpiohd200)
    target_id=69
    modelname="mpiohd200"
    target="MPIO_HD200"
    memory=16 # always
    coldfirecc
    tool="$rootdir/tools/scramble -add=hd20"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 7"
    output="rockbox.mpio"
    bootoutput="bootloader.mpio"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$genericbitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="coldfire"
    t_manufacturer="mpio"
    t_model="hd200"
    ;;

   171|mpiohd300)
    target_id=70
    modelname="mpiohd300"
    target="MPIO_HD300"
    memory=16 # always
    coldfirecc
    tool="$rootdir/tools/scramble -add=hd30"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 2"
    output="rockbox.mpio"
    bootoutput="bootloader.mpio"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$genericbitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="coldfire"
    t_manufacturer="mpio"
    t_model="hd300"
    ;;

   180|rk27generic)
    target_id=78
    modelname="rk27generic"
    target="RK27_GENERIC"
    memory=16 # always
    arm7ejscc
    tool="$rootdir/tools/scramble -rkw -modelnum=73"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.rkw"
    bootoutput="bootloader.rkw"
    appextra="recorder:gui:radio"
    plugins=""
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$genericbitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="rk27xx"
    t_model="rk27generic"
    ;;

   190|hifimanhm60x)
    target_id=79
    modelname="hifimanhm60x"
    target="HM60X"
    memory=16
    arm7ejscc
    tool="$rootdir/tools/scramble -rkw -modelnum=79"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.rkw"
    bootoutput="bootloader.rkw"
    appextra="recorder:gui"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$genericbitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="rk27xx"
    t_model="hm60x"
    ;;

   191|hifimanhm801)
    target_id=82
    modelname="hifimanhm801"
    target="HM801"
    memory=16
    arm7ejscc
    tool="$rootdir/tools/scramble -rkw -modelnum=82"
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox.rkw"
    bootoutput="bootloader.rkw"
    appextra="recorder:gui"
    plugins="yes"
    swcodec="yes"
    # toolset is the tools within the tools directory that we build for
    # this particular target.
    toolset="$genericbitmaptools"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="arm"
    t_manufacturer="rk27xx"
    t_model="hm801"
    ;;

   200|sdlapp)
    application="yes"
    target_id=73
    modelname="sdlapp"
    target="SDLAPP"
    app_set_paths
    app_set_lcd_size
    memory=8
    uname=`uname`
    simcc "sdl-app"
    tool="cp "
    boottool="cp "
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox"
    bootoutput="rockbox"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="hosted"
    t_manufacturer="sdl"
    t_model="app"
    ;;

   201|android)
    application="yes"
    target_id=74
    modelname="android"
    target="ANDROID"
    app_type="android"
    app_set_lcd_size
    sharedir="/data/data/org.rockbox/app_rockbox/rockbox"
    bindir="/data/data/org.rockbox/lib"
    libdir="/data/data/org.rockbox/app_rockbox"
    memory=8
    uname=`uname`
    androidcc armeabi
    tool="cp "
    boottool="cp "
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="librockbox.so"
    bootoutput="librockbox.so"
    appextra="recorder:gui:radio:hosted/android"
    plugins="yes"
    swcodec="yes"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="hosted"
    t_manufacturer="android"
    t_model="app"
    ;;

   202|nokian8xx)
    application="yes"
    target_id=75
    modelname="nokian8xx"
    app_type="sdl-app"
    target="NOKIAN8XX"
    sharedir="/opt/rockbox/share/rockbox"
    bindir="/opt/rockbox/bin"
    libdir="/opt/rockbox/lib"
    memory=8
    uname=`uname`
    maemocc 4
    tool="cp "
    boottool="cp "
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox"
    bootoutput="rockbox"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="hosted"
    t_manufacturer="maemo"
    t_model="app"
    ;;

   203|nokian900)
    application="yes"
    target_id=76
    modelname="nokian900"
    app_type="sdl-app"
    target="NOKIAN900"
    sharedir="/opt/rockbox/share/rockbox"
    bindir="/opt/rockbox/bin"
    libdir="/opt/rockbox/lib"
    memory=8
    uname=`uname`
    maemocc 5
    tool="cp "
    boottool="cp "
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox"
    bootoutput="rockbox"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="hosted"
    t_manufacturer="maemo"
    t_model="app"
    ;;

   204|pandora)
    application="yes"
    target_id=77
    modelname="pandora"
    app_type="sdl-app"
    target="PANDORA"
    sharedir="rockbox/share/rockbox"
    bindir="rockbox/bin"
    libdir="rockbox/lib"
    memory=8
    uname=`uname`
    pandoracc
    tool="cp "
    boottool="cp "
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox"
    bootoutput="rockbox"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="hosted"
    t_manufacturer="pandora"
    t_model="app"
    ;;

   205|samsungypr0)
    application="yes"
    target_id=78
    modelname="samsungypr0"
    target="SAMSUNG_YPR0"
    memory=32
    uname=`uname`
    ypr0cc
    tool="cp "
    boottool="cp "
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="rockbox"
    bootoutput="rockbox"
    appextra="recorder:gui:radio"
    plugins="yes"
    swcodec="yes"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="hosted"
    t_manufacturer="ypr0"
    t_model="app"
    ;;

   206|androidmips)
    application="yes"
    target_id=74
    modelname="androidmips"
    target="ANDROID"
    app_type="android"
    app_set_lcd_size
    sharedir="/data/data/org.rockbox/app_rockbox/rockbox"
    bindir="/data/data/org.rockbox/lib"
    libdir="/data/data/org.rockbox/app_rockbox"
    memory=8
    uname=`uname`
    androidcc mips
    tool="cp "
    boottool="cp "
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="librockbox.so"
    bootoutput="librockbox.so"
    appextra="recorder:gui:radio:hosted/android"
    plugins="yes"
    swcodec="yes"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="hosted"
    t_manufacturer="android"
    t_model="app"
    ;;

   207|androidx86)
    application="yes"
    target_id=74
    modelname="androidx86"
    target="ANDROID"
    app_type="android"
    app_set_lcd_size
    sharedir="/data/data/org.rockbox/app_rockbox/rockbox"
    bindir="/data/data/org.rockbox/lib"
    libdir="/data/data/org.rockbox/app_rockbox"
    memory=8
    uname=`uname`
    androidcc x86
    tool="cp "
    boottool="cp "
    bmp2rb_mono="$rootdir/tools/bmp2rb -f 0"
    bmp2rb_native="$rootdir/tools/bmp2rb -f 4"
    output="librockbox.so"
    bootoutput="librockbox.so"
    appextra="recorder:gui:radio:hosted/android"
    plugins="yes"
    swcodec="yes"
    # architecture, manufacturer and model for the target-tree build
    t_cpu="hosted"
    t_manufacturer="android"
    t_model="app"
    ;;

   *)
    echo "Please select a supported target platform!"
    exit 7
    ;;

  esac

  echo "Platform set to $modelname"


#remove start
############################################################################
# Amount of memory, for those that can differ. They have $memory unset at
# this point.
#

if [ -z "$memory" ]; then
  case $target_id in
  15)
    if [ "$ARG_RAM" ]; then
      size=$ARG_RAM
    else
      echo "Enter size of your RAM (in MB): (Defaults to 32)"
      size=`input`;
    fi
    case $size in
    60|64)
      memory="64"
      ;;
    *)
      memory="32"
      ;;
    esac
    ;;
  *)
    if [ "$ARG_RAM" ]; then
      size=$ARG_RAM
    else
      echo "Enter size of your RAM (in MB): (Defaults to 2)"
      size=`input`;
    fi
    case $size in
    8)
      memory="8"
      ;;
    *)
      memory="2"
      ;;
    esac
    ;;
  esac
  echo "Memory size selected: $memory MB"
  [ "$ARG_TYPE" ] || echo ""
fi
#remove end

##################################################################
# Figure out build "type"
#

  # the ifp7x0 is the only platform that supports building a gdb stub like
  # this
case $modelname in
  iriverifp7xx)
     gdbstub=", (G)DB stub"
     ;;
  sansae200r|sansae200)
     gdbstub=", (I)nstaller"
     ;;
  sansac200)
     gdbstub=", (E)raser"
     ;;
  sansae200)
     gdbstub=", (E)raser"
     ;;
  *)
     ;;
esac
if [ "$CI" ]; then
  btype=$BUILDTYPE
else
  echo "Build (N)ormal, (A)dvanced, (S)imulator, (B)ootloader, (C)heckWPS, (D)atabase tool, (W)arble codec tool$gdbstub: (Defaults to N)"
  btype=`input`;
fi

  case $btype in
    [Ii])
      appsdir='$(ROOTDIR)/bootloader'
      apps="bootloader"
      extradefines="$extradefines -DBOOTLOADER -DE200R_INSTALLER -ffunction-sections -fdata-sections"
      bootloader="1"
      echo "e200R-installer build selected"
      ;;
    [Ee])
      appsdir='$(ROOTDIR)/bootloader'
      apps="bootloader"
      extradefines="$extradefines -DBOOTLOADER -DSANSA_PP_ERASE -ffunction-sections -fdata-sections"
      bootloader="1"
      echo "sansa eraser build selected"
      ;;
    [Bb])
      if test $t_manufacturer = "archos"; then
          # Archos SH-based players do this somewhat differently for
          # some reason
          appsdir='$(ROOTDIR)/flash/bootbox'
          apps="bootbox"
      else
          appsdir='$(ROOTDIR)/bootloader'
          apps="bootloader"
          flash=""
          if test -n "$boottool"; then
              tool="$boottool"
          fi
          if test -n "$bootoutput"; then
              output=$bootoutput
          fi
      fi
      extradefines="$extradefines -DBOOTLOADER -ffunction-sections -fdata-sections"
      bootloader="1"
      echo "Bootloader build selected"
      ;;
    [Ss])
      if [ "$modelname" = "sansae200r" ]; then
          echo "Do not use the e200R target for simulator builds.  Use e200 instead."
          exit 8
      fi
      debug="-DDEBUG"
      simulator="yes"
      extradefines="$extradefines -DSIMULATOR"
      archosrom=""
      flash=""
      echo "Simulator build selected"
      ;;
    [Aa]*)
      echo "Advanced build selected"
      whichadvanced $btype
      ;;
    [Gg])
      extradefines="$extradefines -DSTUB" # for target makefile symbol EXTRA_DEFINES
      appsdir='$(ROOTDIR)/gdb'
      apps="stub"
      case $modelname in
          iriverifp7xx)
              output="stub.wma"
              ;;
          *)
              ;;
      esac
      echo "GDB stub build selected"
      ;;
    [Cc])
      uname=`uname`
      simcc "checkwps"
      toolset='';
      t_cpu='';
      GCCOPTS='';
      rbdir='.'
      extradefines="$extradefines  -DDEBUG"
      appsdir='$(ROOTDIR)/tools/checkwps';
      output='checkwps.'${modelname};
      archosrom='';
      echo "CheckWPS build selected"
      ;;
    [Dd])
      uname=`uname`
      simcc "database-sdl"
      toolset='';
      appsdir='$(ROOTDIR)/tools/database';
      archosrom='';

      case $uname in
          CYGWIN*|MINGW*)
              output="database_${modelname}.exe"
              ;;
          *)
              output='database.'${modelname};
              ;;
      esac
      # architecture, manufacturer and model for the target-tree build
      t_cpu="hosted"
      t_manufacturer="sdl"
      t_model="database"
      echo "Database tool build selected"
      ;;
    [Ww])
      uname=`uname`
      simcc "warble"
      toolset='';
      t_cpu='';
      GCCOPTS='';
      extradefines="$extradefines  -DDEBUG"
      output='warble.'${modelname};
      archosrom='';
      echo "Warble build selected"
      ;;
    *)
      if [ "$modelname" = "sansae200r" ]; then
          echo "Do not use the e200R target for regular builds.  Use e200 instead."
          exit 8
      fi
      debug=""
      btype="N" # set it explicitly since RET only gets here as well
      echo "Normal build selected"
      ;;

  esac
  # to be able running "make manual" from non-manual configuration
  case $modelname in
      archosrecorderv2)
          manualdev="archosfmrecorder"
          ;;
      iriverh1??)
          manualdev="iriverh100"
          ;;
      ipodmini2g)
          manualdev="ipodmini1g"
          ;;
      *)
          manualdev=$modelname
          ;;
  esac

if [ -z "$debug" ]; then
  GCCOPTS="$GCCOPTS $GCCOPTIMIZE"
fi

if [ "yes" = "$application" ]; then
  echo "Building Rockbox as an Application"
  extradefines="$extradefines -DAPPLICATION"
fi

echo "Using source code root directory: $rootdir"

# this was once possible to change at build-time, but no more:
language="english"

uname=`uname`

if [ "yes" = "$simulator" ]; then
  # setup compiler and things for simulator
  simcc "sdl-sim"

  if [ -d "simdisk" ]; then
    echo "Subdirectory 'simdisk' already present"
  else
    mkdir simdisk
    echo "Created a 'simdisk' subdirectory for simulating the hard disk"
  fi
fi

# Now, figure out version number of the (gcc) compiler we are about to use
gccver=`$CC -dumpversion`;

# figure out the binutil version too and display it, mostly for the build
# system etc to be able to see it easier
if [ $uname = "Darwin" ]; then
 ldver=`$LD -v 2>&1 | sed -e 's/[^0-9.-]//g'`
else
 ldver=`$LD --version | head -n 1 | sed -e 's/\ /\n/g' | tail -n 1`
fi

if [ -z "$gccver" ]; then
  echo "[WARNING] The compiler you must use ($CC) is not in your path!"
  echo "[WARNING] this may cause your build to fail since we cannot do the"
  echo "[WARNING] checks we want now."
else

  # gccver should now be "3.3.5", "3.4.3", "2.95.3-6" and similar, but don't
  # DEPEND on it

 num1=`echo $gccver | cut -d . -f1`
 num2=`echo $gccver | cut -d . -f2`
 gccnum=`(expr $num1 "*" 100 + $num2) 2>/dev/null`

 # This makes:
 # 3.3.X  => 303
 # 3.4.X  => 304
 # 2.95.3 => 295

 echo "Using $CC $gccver ($gccnum)"

 if test "$gccnum" -ge "400"; then
   # gcc 4.0 is just *so* much pickier on arguments that differ in signedness
   # so we ignore that warnings for now
   # -Wno-pointer-sign
   GCCOPTS="$GCCOPTS -Wno-pointer-sign"
 fi

 if test "$gccnum" -ge "402"; then
   # disable warning about "warning: initialized field overwritten" as gcc 4.2
   # and later would throw it for several valid cases
   GCCOPTS="$GCCOPTS -Wno-override-init"
 fi

 case $prefix in
   ""|"$CROSS_COMPILE")
     # simulator
   ;;
   *)
   # Verify that the cross-compiler is of a recommended version!
   if test "$gccver" != "$gccchoice"; then
     echo "WARNING: Your cross-compiler $CC $gccver is not of the recommended"
     echo "WARNING: version $gccchoice!"
     echo "WARNING: This may cause your build to fail since it may be a version"
     echo "WARNING: that isn't functional or known to not be the best choice."
     echo "WARNING: If you suffer from build problems, you know that this is"
     echo "WARNING: a likely source for them..."
   fi
   ;;
 esac

fi


echo "Using $LD $ldver"

# check the compiler for SH platforms
if test "$CC" = "sh-elf-gcc"; then
  if test "$gccnum" -lt "400"; then
    echo "WARNING: Consider upgrading your compiler to the 4.0.X series!"
    echo "WARNING: http://www.rockbox.org/twiki/bin/view/Main/CrossCompiler"
  else
    # figure out patch status
    gccpatch=`$CC --version`;

    if { echo $gccpatch | grep "rockbox" >/dev/null 2>&1; } then
      echo "gcc $gccver is rockbox patched"
      # then convert -O to -Os to get smaller binaries!
      GCCOPTS=`echo $GCCOPTS | sed 's/ -O / -Os /'`
    else
      echo "WARNING: You use an unpatched gcc compiler: $gccver"
      echo "WARNING: http://www.rockbox.org/twiki/bin/view/Main/CrossCompiler"
    fi
  fi
fi

if test "$CC" = "m68k-elf-gcc"; then
  # convert -O to -Os to get smaller binaries!
  GCCOPTS=`echo $GCCOPTS | sed 's/ -O / -Os /'`
fi

if [ "$ARG_CCACHE" = "1" ]; then
  echo "Enable ccache for building"
  ccache="ccache"
elif [ "$ARG_CCACHE" != "0" ]; then
  ccache=`findtool ccache`
  if test -n "$ccache"; then
    echo "Found and uses ccache ($ccache)"
  fi
fi

# figure out the full path to the various commands if possible
HOSTCC=`findtool gcc --lit`
HOSTAR=`findtool ar --lit`
CC=`findtool ${CC} --lit`
CPP=`findtool ${CPP} --lit`
LD=`findtool ${LD} --lit`
AR=`findtool ${AR} --lit`
AS=`findtool ${AS} --lit`
OC=`findtool ${OC} --lit`
WINDRES=`findtool ${WINDRES} --lit`
DLLTOOL=`findtool ${DLLTOOL} --lit`
DLLWRAP=`findtool ${DLLWRAP} --lit`
RANLIB=`findtool ${RANLIB} --lit`


if [ -z "$arch" ]; then
    cpp_defines=$(echo "" | $CPP $GCCOPTS -dD)
    if [ -n "$(echo $cpp_defines | grep -w __sh__)" ]; then
        arch="sh"
    elif [ -n "$(echo $cpp_defines | grep -w __m68k__)" ]; then
        arch="m68k"
    elif [ -n "$(echo $cpp_defines | grep -w __arm__)" ]; then
        arch="arm"
        # cpp defines like "#define __ARM_ARCH_4TE__ 1" (where we want to extract the 4)
        arch_version="$(echo $cpp_defines | tr ' ' '\012' | grep __ARM_ARCH | sed -e 's,.*\([0-9]\).*,\1,')"
    elif [ -n "$(echo $cpp_defines | grep -w __mips__)" ]; then
        arch="mips"
        arch_version="$(echo $cpp_defines | tr ' ' '\012' | grep _MIPS_ARCH_MIPS | sed -e 's,.*\([0-9][0-9]\).*,\1,')"
    elif [ -n "$(echo $cpp_defines | grep -w __i386__)" ]; then
        arch="x86"
    elif [ -n "$(echo $cpp_defines | grep -w __x86_64__)" ]; then
        arch="amd64"
    else
        arch="none"
        echo "Warning: Could not determine target arch"
    fi
    if [ "$arch" != "none" ]; then        
        if [ -n "$arch_version" ]; then
            echo "Automatically selected arch: $arch (ver $arch_version)"
        else
            echo "Automatically selected arch: $arch"
        fi
    fi;
else
    if [ -n "$arch_version" ]; then
        echo "Manually selected arch: $arch (ver $arch_version)"
    else
        echo "Manually selected arch: $arch"
    fi
fi

arch="arch_$arch"
if [ -n "$arch_version" ]; then
    Darch_version="#define ARCH_VERSION $arch_version"
fi

if test -n "$ccache"; then
  CC="$ccache $CC"
fi

if test "$ARG_ARM_THUMB" = "1"; then
  extradefines="$extradefines -DUSE_THUMB"
  CC="$toolsdir/thumb-cc.py $CC"
fi

if test "X$endian" = "Xbig"; then
  defendian="ROCKBOX_BIG_ENDIAN"
else
  defendian="ROCKBOX_LITTLE_ENDIAN"
fi

if [ "$ARG_RBDIR" != "" ]; then
    if [ -z `echo $ARG_RBDIR | grep '^/'` ]; then
        rbdir="/"$ARG_RBDIR
    else
        rbdir=$ARG_RBDIR
    fi 
  echo "Using alternate rockbox dir: ${rbdir}"
fi

cat > autoconf.h <<EOF
/* This header was made by configure */
#ifndef __BUILD_AUTOCONF_H
#define __BUILD_AUTOCONF_H

/* lower case names match the what's exported in the Makefile
 * upper case name looks nicer in the code */

#define arch_none 0
#define ARCH_NONE 0

#define arch_sh 1
#define ARCH_SH 1

#define arch_m68k 2
#define ARCH_M68K 2

#define arch_arm 3
#define ARCH_ARM 3

#define arch_mips 4
#define ARCH_MIPS 4

#define arch_x86 5
#define ARCH_X86 5

#define arch_amd64 6
#define ARCH_AMD64 6

/* Define target machine architecture */
#define ARCH ${arch}
/* Optionally define architecture version */
${Darch_version}

/* Define endianess for the target or simulator platform */
#define ${defendian} 1

/* Define the GCC version used for the build */
#define GCCNUM ${gccnum}

/* Define this if you build rockbox to support the logf logging and display */
${use_logf}

/* Define this if you want logf to output to the serial port */
${use_logf_serial}

/* Define this to record a chart with timings for the stages of boot */
${use_bootchart}

/* optional define for a backlight modded Ondio */
${have_backlight}

/* optional define for FM radio mod for iAudio M5 */
${have_fmradio_in}

/* optional define for ATA poweroff on Player */
${have_ata_poweroff}

/* optional defines for RTC mod for h1x0 */
${config_rtc}
${have_rtc_alarm}

/* the threading backend we use */
#define ${thread_support}

/* lcd dimensions for application builds from configure */
${app_lcd_width}
${app_lcd_height}

/* root of Rockbox */
#define ROCKBOX_DIR "${rbdir}"
#define ROCKBOX_SHARE_PATH "${sharedir}"
#define ROCKBOX_BINARY_PATH "${bindir}"
#define ROCKBOX_LIBRARY_PATH "${libdir}"

#endif /* __BUILD_AUTOCONF_H */
EOF

if test -n "$t_cpu"; then
  TARGET_INC="-I\$(FIRMDIR)/target/$t_cpu/$t_manufacturer/$t_model"

  if [ "$application" = "yes" ] && [ "$t_manufacturer" = "maemo" ]; then
    # Maemo needs the SDL port, too
    TARGET_INC="$TARGET_INC -I\$(FIRMDIR)/target/hosted/sdl/app"
    TARGET_INC="$TARGET_INC -I\$(FIRMDIR)/target/hosted/sdl"
  elif [ "$application" = "yes" ] && [ "$t_manufacturer" = "pandora" ]; then
    # Pandora needs the SDL port, too
    TARGET_INC="$TARGET_INC -I\$(FIRMDIR)/target/hosted/sdl/app"
    TARGET_INC="$TARGET_INC -I\$(FIRMDIR)/target/hosted/sdl"
  elif [ "$simulator" = "yes" ]; then # a few more includes for the sim target tree
    TARGET_INC="$TARGET_INC -I\$(FIRMDIR)/target/hosted/sdl"
    TARGET_INC="$TARGET_INC -I\$(FIRMDIR)/target/hosted"
  fi

  TARGET_INC="$TARGET_INC -I\$(FIRMDIR)/target/$t_cpu/$t_manufacturer"
  test -n "$t_soc" && TARGET_INC="$TARGET_INC -I\$(FIRMDIR)/target/$t_cpu/$t_soc"
  TARGET_INC="$TARGET_INC -I\$(FIRMDIR)/target/$t_cpu"
  GCCOPTS="$GCCOPTS"
fi

if test "$swcodec" = "yes"; then
  voicetoolset="rbspeexenc voicefont wavtrim"
else
  voicetoolset="voicefont wavtrim"
fi

if test "$apps" = "apps"; then
  # only when we build "real" apps we build the .lng files
  buildlangs="langs"
fi

#### Fix the cmdline ###
if [ -n "$ARG_PREFIX" ]; then
  cmdline="$cmdline --prefix=\$(PREFIX)"
fi
if [ -n "$ARG_LCDWIDTH" ]; then
  cmdline="$cmdline --lcdwidth=$ARG_LCDWIDTH --lcdheight=$ARG_LCDHEIGHT "
fi

# remove parts from the cmdline we're going to set unconditionally
cmdline=`echo $cmdline | sed -e s,--target=[a-zA-Z_0-9]\*,,g \
                            -e s,--ram=[0-9]\*,,g \
                            -e s,--rbdir=[./a-zA-Z0-9]\*,,g \
                            -e s,--type=[a-zA-Z]\*,,g`
cmdline="$cmdline --target=\$(MODELNAME) --ram=\$(MEMORYSIZE) --rbdir=\$(RBDIR) --type=$btype$advopts"

### end of cmdline

cat > Makefile <<EOF
## Automatically generated. http://www.rockbox.org/

export ROOTDIR=${rootdir}
export FIRMDIR=\$(ROOTDIR)/firmware
export APPSDIR=${appsdir}
export TOOLSDIR=${toolsdir}
export DOCSDIR=${rootdir}/docs
export MANUALDIR=${rootdir}/manual
export DEBUG=${debug}
export MODELNAME=${modelname}
export ARCHOSROM=${archosrom}
export FLASHFILE=${flash}
export TARGET_ID=${target_id}
export TARGET=-D${target}
export ARCH=${arch}
export ARCH_VERSION=${arch_version}
export CPU=${t_cpu}
export MANUFACTURER=${t_manufacturer}
export OBJDIR=${pwd}
export BUILDDIR=${pwd}
export RBCODEC_BLD=${pwd}/lib/rbcodec
export LANGUAGE=${language}
export VOICELANGUAGE=${voicelanguage}
export MEMORYSIZE=${memory}
export BUILDDATE:=\$(shell date -u +'-DYEAR=%Y -DMONTH=%m -DDAY=%d')
export MKFIRMWARE=${tool}
export BMP2RB_MONO=${bmp2rb_mono}
export BMP2RB_NATIVE=${bmp2rb_native}
export BMP2RB_REMOTEMONO=${bmp2rb_remotemono}
export BMP2RB_REMOTENATIVE=${bmp2rb_remotenative}
export BINARY=${output}
export APPEXTRA=${appextra}
export ENABLEDPLUGINS=${plugins}
export SOFTWARECODECS=${swcodec}
export EXTRA_DEFINES=${extradefines}
export HOSTCC=${HOSTCC}
export HOSTAR=${HOSTAR}
export CC=${CC}
export CPP=${CPP}
export LD=${LD}
export AR=${AR}
export AS=${AS}
export OC=${OC}
export WINDRES=${WINDRES}
export DLLTOOL=${DLLTOOL}
export DLLWRAP=${DLLWRAP}
export RANLIB=${RANLIB}
export PREFIX=${ARG_PREFIX}
export PROFILE_OPTS=${PROFILE_OPTS}
export APP_TYPE=${app_type}
export APPLICATION=${application}
export SIMDIR=\$(ROOTDIR)/uisimulator/sdl
export GCCOPTS=${GCCOPTS}
export TARGET_INC=${TARGET_INC}
export LOADADDRESS=${loadaddress}
export SHARED_LDFLAG=${SHARED_LDFLAG}
export SHARED_CFLAGS=${SHARED_CFLAGS}
export LDOPTS=${LDOPTS}
export GLOBAL_LDOPTS=${GLOBAL_LDOPTS}
export GCCVER=${gccver}
export GCCNUM=${gccnum}
export UNAME=${uname}
export MANUALDEV=${manualdev}
export TTS_OPTS=${TTS_OPTS}
export TTS_ENGINE=${TTS_ENGINE}
export ENC_OPTS=${ENC_OPTS}
export ENCODER=${ENCODER}
export USE_ELF=${USE_ELF}
export RBDIR=${rbdir}
export ROCKBOX_SHARE_PATH=${sharedir}
export ROCKBOX_BINARY_PATH=${bindir}
export ROCKBOX_LIBRARY_PATH=${libdir}
export SDLCONFIG=${sdl}
export LCDORIENTATION=${lcd_orientation}
export ANDROID_ARCH=${ANDROID_ARCH}

CONFIGURE_OPTIONS=${cmdline}

include \$(TOOLSDIR)/root.make
EOF
kill "$x"
echo "COMPLETED"