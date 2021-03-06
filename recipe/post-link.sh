#!/bin/bash

if [ "$(uname)" == "Darwin" ]; then
    # This post-link script is to fix portability problems
    # with our gcc package on Linux. It isn't needed on OSX.
    exit 0;
fi

build_os_md5=( $(md5sum "${PREFIX}/share/conda-gcc-build-machine-os-details") )
target_os_md5=( $(cat /etc/*-release | md5sum) )

# No need to make any portability fixes if
# we're deploying to the same OS we built with.
if [[ "${build_os_md5[0]}" == "${target_os_md5[0]}" ]]; then
    echo "gcc install OS matches gcc build OS: Skipping post-link portability fixes."
else

    # In this script, we attempt to fix 3 Linux distro portability issues:

    #
    # Linux Portability Issue #1: "fixed includes"
    #

    # Remove the headers that gcc "fixed" as part of the gcc build process.
    # They kill the gcc binary's portability to other systems,
    #   and shouldn't be necessary on ANSI-compliant systems anyway.
    # See this informative writeup of the problem:
    # http://ewontfix.com/12/
    #
    # More discussion can be found here:
    # https://groups.google.com/a/continuum.io/d/msg/conda/HwUazgD-hJ0/aofO0vD-MhcJ
    while read -r x ; do
      grep -q 'It has been auto-edited by fixincludes from' "${x}" \
               && rm -f "${x}"
    done < <(find "${PREFIX}"/lib/gcc/*/*/include*/ -name '*.h')

    #
    # Linux Portability Issue #2: linker needs to locate crtXXX.o
    #

    # Locate the system's C-runtime object files and link them into the gcc
    #  build so they are automatically on the gcc search path.
    # (The location of these files varies from one system to the next.)
    C_RUNTIME_OBJ_FILES="crt0.o crt1.o crt2.o crt3.o crti.o crtn.o"

    c_runtime_obj_files_found=0

    # Try locating crtXXX.o in default library search paths
    for library_path in $(/usr/bin/ld --verbose | grep SEARCH_DIR | sed -r 's/SEARCH_DIR\("=?([^"]*)"\);/ \1/g'); do
        for obj_file in $C_RUNTIME_OBJ_FILES; do
            obj_file_full_path="$library_path/$obj_file"
            if [[ -e "$obj_file_full_path" ]]; then
                ln -s "$obj_file_full_path" "${PREFIX}/lib/gcc/"*/*/
                c_runtime_obj_files_found=1
            fi
        done
        if [ $c_runtime_obj_files_found -eq 1 ]; then
            break
        fi
    done

    # Fallback to locating crtXXX.o with system gcc we if couldn't find it in usual places
    if [ $c_runtime_obj_files_found -ne 1 ]; then
        echo "Couldn't locate crtXXX.o in default library search paths. You may not have it " \
             "at all. It is usually packaged in libc6-dev/glibc-devel packages. We will try " \
             "to locate crtXXX.o with system installed gcc..."

        SYSTEM_GCC=/usr/bin/gcc

        if [ -e "${SYSTEM_GCC}" ]; then
            for obj_file in $C_RUNTIME_OBJ_FILES; do
                obj_file_full_path=$($SYSTEM_GCC -print-file-name="$obj_file")
                if [[ "$obj_file_full_path" != "$obj_file" ]]; then
                    ln -s "$obj_file_full_path" "${PREFIX}/lib/gcc/"*/*/
                    c_runtime_obj_files_found=1
                fi
            done
        else
            echo "There is no $SYSTEM_GCC"
        fi
    fi

    if [ $c_runtime_obj_files_found -ne 1 ]; then
        >&2 echo "*** Can't install the gcc package unless your system has crtXXX.o. ***"
        exit 1
    fi

    #
    # Linux Portability Issue #3: Compiler needs to locate system headers
    #

    # Some distros use different system include paths than the ones this gcc binary was built for.
    # We'll add these to the standard include path by providing a custom "specs file"

    # First create specs file from existing defaults
    SPECS_DIR=$(echo "${PREFIX}"/lib/gcc/*/*)
    SPECS_FILE="${SPECS_DIR}/specs"
    "${PREFIX}"/bin/gcc -dumpspecs > "${SPECS_FILE}"

    # Now add extra include paths to the specs file, one at a time.
    # (So far we only know of one: from Ubuntu.)
    EXTRA_SYSTEM_INCLUDE_DIRS="/usr/include/x86_64-linux-gnu /usr/include/i686-linux-gnu /usr/include/i386-linux-gnu"

    for INCDIR in ${EXTRA_SYSTEM_INCLUDE_DIRS}; do
        # The following sed command will replace these two lines:
        # *cpp:
        # ... yada yada ...
        #
        # With these two lines:
        # *cpp:
        # ... yada yada ... -isystem ${INCDIR}
        sed -i ':a;N;$!ba;s|\(*cpp:\n[^\n]*\)|\1 -isystem '${INCDIR}'|g' "${SPECS_FILE}"
    done

    #
    # Linux Portability Issue #2.5: linker also needs to find the rest of libc (i.e. libc.so in addition to crtXXX.o)
    #
    for library_path in $(/usr/bin/ld --verbose | grep SEARCH_DIR | sed -r 's/SEARCH_DIR\("=?([^"]*)"\);/ \1/g'); do
         sed -i ':a;N;$!ba;s|\(*link_libgcc:\n[^\n]*\)|\1 -L'${library_path}'|g' "${SPECS_FILE}"
    done
fi
