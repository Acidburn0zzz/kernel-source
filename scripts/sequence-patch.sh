#! /bin/bash

source $(dirname $0)/config.sh

usage() {
    echo "SYNOPSIS: $0 [-qv] [--arch=...] [--symbol=...] [--dir=...] [--combine] [--fast] [last-patch-name]"
    exit 1
}

# Allow to pass in default arguments via SEQUENCE_PATCH_ARGS.
set -- $SEQUENCE_PATCH_ARGS "$@"

options=`getopt -o qvd: --long quilt,arch:,symbol:,dir:,combine,fast -- "$@"`

if [ $? -ne 0 ]
then
    usage
fi

eval set -- "$options"

QUIET=1
EXTRA_SYMBOLS=
CLEAN=1
COMBINE=
FAST=

while true; do
    case "$1" in
    	-q)
	    QUIET=1
	    ;;
    	-v)
	    QUIET=
	    ;;
	--quilt)
	    CLEAN=
	    ;;
	--combine)
	    COMBINE=1
	    FAST=1
	    ;;
       	--fast)
	    FAST=1
	    ;;
	--arch)
	    export PATCH_ARCH=$2
	    shift
	    ;;
	--symbol)
	    EXTRA_SYMBOLS="$EXTRA_SYMBOLS $2"
	    shift
	    ;;
	-d|--dir)
	    SCRATCH_AREA=$2
	    shift
	    ;;
	--)
	    shift
	    break ;;
	*)
	    usage ;;
    esac
    shift
done

unset LIMIT
if [ $# -ge 1 ]; then
    LIMIT=$1
    shift
fi

if [ $# -ne 0 ]; then
    usage
fi

# Some patches require patch 2.5.4. Abort with older versions.
PATCH_VERSION=$(patch -v | sed -e '/^patch/!d' -e 's/patch //')
case $PATCH_VERSION in
    ([01].*|2.[1-4].*|2.5.[1-3])  # (check if < 2.5.4)
	echo "patch version $PATCH_VERSION found; " \
	     "a version >= 2.5.4 required." >&2
	exit 1
    ;;
esac

# Check SCRATCH_AREA.
if [ -z "$SCRATCH_AREA" ]; then
    echo "SCRATCH_AREA not defined (set to /var/tmp/scratch or similar)"
    exit 1
fi
if [ ! -d "$SCRATCH_AREA" ]; then
    if ! mkdir -p $SCRATCH_AREA; then
	echo "creating scratch dir $SCRATCH_AREA failed"
	exit 1
    fi
fi

[ "${SCRATCH_AREA:0:1}" != "/" ] \
    && SCRATCH_AREA="$PWD/$SCRATCH_AREA"

TMPDIR=$SCRATCH_AREA
export TMPDIR
ORIG_DIR=$SCRATCH_AREA/linux-$SRCVERSION.orig
TAG="$(sed -ne 's:^T::p' $(dirname $0)/../CVS/Tag 2>/dev/null)"
PATCH_DIR=$SCRATCH_AREA/linux-$SRCVERSION${TAG:+-$TAG}
PATCH_LOG=$SCRATCH_AREA/patch-$SRCVERSION${TAG:+-$TAG}.log
LAST_LOG=$SCRATCH_AREA/last-$SRCVERSION${TAG:+-$TAG}.log

# Check if we can clean up backup files at the end
# (slightly faster, but requires more disk space).
free_blocks="$(df -P "$SCRATCH_AREA" \
    | awk 'NR==2 && match($4, /^[0-9]*$/) { print $4 }' 2> /dev/null)"
[ "0$free_blocks" -gt 262144 ] && enough_free_space=1

echo "Creating tree in $PATCH_DIR"

if [ ! -d $ORIG_DIR ]; then
    # Check if linux-$SRCVERSION.tar.gz is accessible.
    for file in {$SCRATCH_AREA/,,$MIRROR/,$MIRROR/testing/}linux-$SRCVERSION.tar.{gz,bz2}; do
	if [ -r $file ]; then
	    LINUX_ORIG_TARBALL=$file
	    [ ${file:(-3)} = .gz  ] && COMPRESS_MODE=z
	    [ ${file:(-4)} = .bz2 ] && COMPRESS_MODE=j
	    break
	fi
    done
    if [ -z "$LINUX_ORIG_TARBALL" ]; then
	echo "Kernel source archive \`linux-$SRCVERSION.tar.gz' not found," >&2
	echo "alternatively you can put an unpatched kernel tree to" >&2
	echo "$ORIG_DIR." >&2
	exit 1
    fi
fi

# Check series.conf.
if [ ! -r series.conf ]; then
    echo "Configuration file \`series.conf' not found"
    exit 1
fi
if [ -e scripts/check-patches ]; then
    scripts/check-patches || {
	echo "Inconsistencies found."
	echo "Please clean up series.conf and/or the patches directories!"
	read
    }
fi

if [ -z "$SYMBOLS" ]; then
    if [ -z "$ARCH_SYMBOLS" ]; then
	if [ -x arch-symbols ]; then
	    ARCH_SYMBOLS=arch-symbols
	elif [ -x scripts/arch-symbols ]; then
	    ARCH_SYMBOLS=scripts/arch-symbols
	else
	    echo "Cannot locate \`arch-symbols' script (export ARCH_SYMBOLS)"
	    exit 1
	fi
    else
	if [ ! -x "$ARCH_SYMBOLS" ]; then
	    echo "Cannot execute \`arch-symbols' script"
	    exit 1
	fi
    fi
    SYMBOLS=$($ARCH_SYMBOLS)
    if [ -z "$SYMBOLS" ]; then
	echo "Unsupported architecture \`$ARCH'" >&2
	exit 1
    fi
fi

echo "Architecture symbol(s): $SYMBOLS"
if [ -s extra-symbols ]; then
	EXTRA_SYMBOLS="$EXTRA_SYMBOLS $(cat extra-symbols)"
fi
if [ -n "$EXTRA_SYMBOLS" ]; then
    echo "Extra symbols: $EXTRA_SYMBOLS"
    SYMBOLS="$SYMBOLS $EXTRA_SYMBOLS"
fi

# Clean up from previous run
rm -f "$PATCH_LOG" "$LAST_LOG"
if [ -e $PATCH_DIR ]; then
    tmpdir=$(mktemp -d ${PATCH_DIR%/*}/${0##*/}.XXXXXX)
    if [ -n "$tmpdir" ]; then
	echo "Cleaning up from previous run (background)"
	mv $PATCH_DIR $tmpdir
	rm -rf $tmpdir &
    else
	echo "Cleaning up from previous run"
	rm -rf $PATCH_DIR
    fi
fi

# Create fresh $SCRATCH_AREA/linux-$SRCVERSION.
if ! [ -d $ORIG_DIR ]; then
    echo "Extracting $LINUX_ORIG_TARBALL"
    tar xf$COMPRESS_MODE $LINUX_ORIG_TARBALL --directory $SCRATCH_AREA
    if [ -e $SCRATCH_AREA/linux-$SRCVERSION ]; then
	mv $SCRATCH_AREA/linux-$SRCVERSION $ORIG_DIR || exit 1
    elif [ -e $SCRATCH_AREA/linux ]; then
	# Old kernels unpack into linux/ instead of linux-$SRCVERSION/.
	mv $SCRATCH_AREA/linux $ORIG_DIR || exit 1
    fi
    find $ORIG_DIR -type f | xargs chmod a-w,a+r
fi

PATCHES=( $(scripts/guards $SYMBOLS < series.conf) )

# Check if patch $LIMIT exists
if [ -n "$LIMIT" ]; then
    for ((n=0; n<${#PATCHES[@]}; n++)); do
	if [ "$LIMIT" = - ]; then
	    LIMIT=${PATCHES[n]}
	    break
	fi
	case "${PATCHES[n]}" in
	$LIMIT|*/$LIMIT)
	    LIMIT=${PATCHES[n]}
	    break
	    ;;
	esac
    done
    if ((n == ${#PATCHES[@]})); then
	echo "No patch \`$LIMIT' found."
	exit 1
    fi
    PATCHES_BEFORE=()
    for ((m=0; m<n; m++)); do
	PATCHES_BEFORE[m]=${PATCHES[m]}
    done
    PATCHES_AFTER=()
    for ((m=n; m<${#PATCHES[@]}; m++)); do
	PATCHES_AFTER[m-n]=${PATCHES[m]}
    done
else
    PATCHES_BEFORE=( "${PATCHES[@]}" )
    PATCHES_AFTER=()
fi

if [ -n "$COMBINE" ]; then
    echo "Precomputing combined patches"
    (IFS=$'\n'; echo "${PATCHES[*]}") \
    | $(dirname $0)/md5fast --dir "$SCRATCH_AREA" --source-tree "$ORIG_DIR" \
    			    --cache combined --generate
fi

if [ -n "$FAST" -a -d combined -a ${#PATCHES_BEFORE[@]} -gt 0 ]; then
    echo "Checking for precomputed combined patches"
    PATCHES=( $(IFS=$'\n'; echo "${PATCHES_BEFORE[*]}" \
	        | $(dirname $0)/md5fast --dir "$SCRATCH_AREA" --cache combined)
    	      "${PATCHES_AFTER[@]}" )
fi

# Helper function to restore files backed up by patch. This is
# faster than doing a --dry-run first.
restore_files() {
    local backup_dir=$1 patch_dir=$2 file wd=$PWD
    local -a remove restore
 
    if [ -d $backup_dir ]; then
	pushd $backup_dir > /dev/null
	for file in $(find . -type f) ; do
	    if [ -s "$file" ]; then
		restore[${#restore[@]}]="$file"
	    else
		remove[${#remove[@]}]="$file"
	    fi
	done
	#echo "Restore: ${restore[@]}"
	[ ${#restore[@]} -ne 0 ] \
	    && cp -f --parents "${restore[@]}" $patch_dir
	cd $patch_dir
	#echo "Remove: ${remove[@]}"
	[ ${#remove[@]} -ne 0 ] \
	    && rm -f "${remove[@]}"
	popd > /dev/null
    fi
}

# Create hardlinked source tree
echo "Linking from $ORIG_DIR"
cp -rld $ORIG_DIR $PATCH_DIR

echo -e "# Symbols: $SYMBOLS\n#" > $PATCH_DIR/series
SERIES_PFX=
if [ -n "$CLEAN" ]; then
    SERIES_PFX="# "
fi

mkdir $PATCH_DIR/.pc
echo 2 > $PATCH_DIR/.pc/.version

# Patch kernel
set -- "${PATCHES[@]}"
while [ $# -gt 0 ]; do
    PATCH="$1"
    if [ "$PATCH" = "$LIMIT" -a -n "$CLEAN" ]; then
	STEP_BY_STEP=1
	echo "Stopping before $PATCH"
    fi
    if [ -n "$STEP_BY_STEP" ]; then
	while true; do
	    echo -n "Continue ([y]es/[n]o/yes to [a]ll)?"
	    read YESNO
	    case $YESNO in
		([yYjJsS])
		    break
		    ;;
		([nN])
		    break 2	# break out of outer loop
		    ;;
		([aA])
		    unset STEP_BY_STEP
		    break
		    ;;
	    esac
	done
    fi

    if [ ! -r "$PATCH" ]; then
	echo "Patch $PATCH not found."
	status=1
	break
    fi
    echo "[ $PATCH ]"
    echo "[ $PATCH ]" >> $PATCH_LOG
    backup_dir=$PATCH_DIR/.pc/$PATCH

    exec 5<&1  # duplicate stdin
    case $PATCH in
    *.gz)	exec < <(gzip -cd $PATCH) ;;
    *.bz2)	exec < <(bzip2 -cd $PATCH) ;;
    *)		exec < $PATCH ;;
    esac
    patch -d $PATCH_DIR --backup --prefix=$backup_dir/ -p1 -E \
	    --no-backup-if-mismatch > $LAST_LOG 2>&1
    STATUS=$?
    exec 0<&5  # restore stdin
    
    [ $STATUS -ne 0 ] \
	&& restore_files $backup_dir $PATCH_DIR
    [ -n "$CLEAN" -a -z "$enough_free_space" ] \
	&& rm -rf $PATCH_DIR/.pc/
    cat $LAST_LOG >> $PATCH_LOG
    [ -z "$QUIET" ] && cat $LAST_LOG
    if [ $STATUS -ne 0 ]; then
	[ -n "$QUIET" ] && cat $LAST_LOG
	echo "Patch $PATCH failed (rolled back)."
	echo "Logfile: $PATCH_LOG"
	status=1
	break
    else
	echo "$SERIES_PFX$PATCH" >> $PATCH_DIR/series
	[ -z "$CLEAN" ] \
	    && echo "$PATCH" >> $PATCH_DIR/.pc/applied-patches
	rm -f $LAST_LOG
    fi

    shift
    if [ "$PATCH" = "$LIMIT" -a -z "$CLEAN" ]; then
	break
    fi
done

[ -n "$CLEAN" -a -n "$enough_free_space" ] \
    && rm -rf $PATCH_DIR/.pc/

if [ -n "$CLEAN" ]; then
    rm $PATCH_DIR/series
fi

ln -s $PWD $PATCH_DIR/patches
# If there are any remaining patches, add them to the series so
# they can be fixed up with quilt (or similar).
if [ -n "$*" ]; then
    ( IFS=$'\n' ; echo "$*" ) >> $PATCH_DIR/series
fi

echo "[ Tree: $PATCH_DIR ]"

[ $# -gt 0 ] && exit $status

# Old kernels don't have a config.conf.
[ -e config.conf ] || exit

# Copy the config files that apply for this kernel.
echo "[ Copying config files ]" >> $PATCH_LOG
echo "[ Copying config files ]"
TMPFILE=$(mktemp /tmp/$(basename $0).XXXXXX)
chmod a+r $TMPFILE
CONFIGS=$(scripts/guards --list < config.conf)
for config in $CONFIGS; do
    if ! [ -e config/$config ]; then
	echo "Configuration file config/$config not found"
    fi
    name=$(basename $config)
    path=arch/$(dirname $config)/defconfig.$name
    mkdir -p $(dirname $PATCH_DIR/$path)

    chmod +x rpm/config-subst
    cat config/$config \
    | rpm/config-subst CONFIG_CFGNAME \"$name\" \
    | rpm/config-subst CONFIG_RELEASE \"0\" \
    | rpm/config-subst CONFIG_SUSE_KERNEL y \
    > $TMPFILE

    echo $path >> $PATCH_LOG
    [ -z "$QUIET" ] && echo $path
    # Make sure we don't override a hard-linked file.
    rm -f $PATCH_DIR/$path
    cp -f $TMPFILE $PATCH_DIR/$path
done
rm -f $TMPFILE
