#!/bin/bash

. ${0%/*}/wd-functions.sh

rpm_release_timestamp=
rpm_release_string=
source_timestamp=
tolerate_unknown_new_config_options=0
ignore_kabi=
ignore_unsupported_deps=
until [ "$#" = "0" ] ; do
  case "$1" in
    --dir=*)
      build_dir=${1#*=}
      shift
      ;;
    -d|--dir)
      build_dir=$2
      shift 2
      ;;
    --embargo)
      embargo_filter=1
      shift
      ;;
    -nf|--tolerate-unknown-new-config-options)
      tolerate_unknown_new_config_options=1
      shift
      ;;
    -i|--ignore-kabi)
      ignore_kabi=1
      shift
      ;;
    -iu|--ignore-unsupported-deps)
      ignore_unsupported_deps=1
      shift
      ;;
    -rs|--release-string)
      case "$2" in
      *[' '-]*)
        echo "$1 option argument must not contain dashes or spaces" >&2
	exit 1
	;;
      esac
      rpm_release_string="$2"
      shift 2
      ;;
    -ts|--timestamp)
      rpm_release_timestamp=yes
      shift
      ;;
    -k|--kbuild|--source-timestamp)
      source_timestamp=1
      shift
      ;;
    -u|--update-only)
      update_only=1
      shift
      ;;
    -h|--help|-v|--version)
	cat <<EOF

${0##*/} perpares a 'kernel-source' package for submission into autobuild

these options are recognized:
    -rs <string>       to append specified string to rpm release number
    -ts                to use the current date as rpm release number
    -nf                to proceed if a new unknown .config option is found during make oldconfig
    -u		       update generated files in an existing kernel-source dir
    -i                 ignore kabi failures
    --source-timestamp to autogenerate a release number based on branch and timestamp (overrides -rs/-ts)

EOF
	exit 1
	;;
    *)
      echo "unknown option '$1'" >&2
      exit 1
      ;;
  esac
done
source $(dirname $0)/config.sh
export LANG=POSIX
SRC_FILE=linux-$SRCVERSION.tar.bz2
PATCHVERSION=$($(dirname $0)/compute-PATCHVERSION.sh)

case "$PATCHVERSION" in
*-*)
    RPMVERSION=${PATCHVERSION%%-*}
    RELEASE_PREFIX=${PATCHVERSION#*-}.
    RELEASE_PREFIX=${RELEASE_PREFIX//-/.}
    ;;
*)
    RPMVERSION=$PATCHVERSION
    RELEASE_PREFIX=
    ;;
esac

if [ -n "$rpm_release_timestamp" ]; then
    if test $(( ${#RPMVERSION} + 10 + 2 + 8 + ${#rpm_release_string})) -gt 64
    then
    	echo "${RPMVERSION}-${rpm_release_string}-\${flavour} exceeds the 64 byte 'uname -r' limit. Use a shorter string."
	exit 1
    fi
    rpm_release_string="\`env -i - TZ=GMT date +%Y%m%d\`${rpm_release_string:+_$rpm_release_string}"
fi

[ -z "$build_dir" ] && build_dir=$BUILD_DIR
if [ -z "$build_dir" ]; then
    echo "Please define the build directory with the --dir option" >&2
    exit 1
fi

check_for_merge_conflicts() {
    set -- $(grep -lP '^<{7}(?!<)|^>{7}(?!>)' "$@" 2> /dev/null)
    if [ $# -gt 0 ]; then
	printf "Merge conflicts in %s\n" "$@" >&2
	return 1
    fi
}

if [ -n "$update_only" ]; then
	if [ ! -d "$build_dir" ]; then
		echo "$build_dir must exist in update mode."
		exit 1
	fi
else
	rm -rf $build_dir
	mkdir -p $build_dir
fi

# generate the list of patches to include.
if [ -n "$embargo_filter" ]; then
    scripts/embargo-filter < series.conf > $build_dir/series.conf \
	|| exit 1
    chmod 644 $build_dir/series.conf
else
    install -m 644 series.conf $build_dir/
fi

# All config files and patches used
referenced_files="$( {
	$(dirname $0)/guards --list < $build_dir/series.conf
	$(dirname $0)/guards --prefix=config --list < config.conf
    } | sort -u )"

inconsistent=false
check_for_merge_conflicts $referenced_files kernel-source.changes{,.old} || \
	inconsistent=true
scripts/check-conf || inconsistent=true
scripts/check-cvs-add --committed || inconsistent=true
if $inconsistent; then
    echo "Inconsistencies found."
    echo "Please clean up series.conf and/or the patches directories!"
    echo
fi

if ! scripts/cvs-wd-timestamp > $build_dir/build-source-timestamp; then
    exit 1
fi

if $using_git; then
    # Always include the git revision
    echo "GIT Revision: $(git rev-parse HEAD)" >> $build_dir/build-source-timestamp
    tag=$(get_branch_name)
    if test -n "$tag"; then
	echo "GIT Branch: $tag" >>$build_dir/build-source-timestamp
    fi
    git_commit=$(git rev-parse HEAD)
    git_commit=${git_commit:0:8}
fi

if [ -n "$source_timestamp" ]; then
	ts="$(head -n 1 $build_dir/build-source-timestamp)"
	branch=$(sed -nre 's/^GIT Branch: //p' \
		 $build_dir/build-source-timestamp)
	rpm_release_string=${branch}_$(date --utc '+%Y%m%d%H%M%S' -d "$ts")
fi

sed -e "s:@RELEASE_PREFIX@:$RELEASE_PREFIX:"     \
    -e "s:@RELEASE_SUFFIX@:$rpm_release_string:" \
    -e "s:@COMMIT@:$git_commit:"                 \
    rpm/get_release_number.sh.in                 \
    > $build_dir/get_release_number.sh
chmod 755 $build_dir/get_release_number.sh
RELEASE=$($build_dir/get_release_number.sh)

# List all used configurations
config_files="$(
    for arch in $(scripts/arch-symbols --list) ; do
	scripts/guards $arch < config.conf \
	| sed -e "s,^,$arch ,"
    done)"
flavors="$(echo "$config_files" | sed -e 's,.*/,,' | sort -u)"

for flavor in $flavors ; do
    echo "kernel-$flavor.spec"

    # Find all architectures for this spec file
    set -- $(
	echo "$config_files" \
	| sed -e "/\/$flavor/!d" \
	      -e "s, .*,,g" \
	| sort -u)
    archs="$*"
    
    # Compute @PROVIDES_OBSOLETES@ expansion
    head=""
    for arch in $archs ; do
	p=( $(scripts/guards $arch $flavor p \
		< rpm/old-packages.conf) )
	o=( $(scripts/guards $arch $flavor o \
		< rpm/old-packages.conf) )

	# Do we have an override config file or an additional patch?
	if [ -e $arch-$flavor.conf ]; then
	    echo "Override config: $arch-$flavor.conf"
	    cp $arch-$flavor.conf $build_dir/
	fi
	if [ -e $arch-$flavor.diff ]; then
	    echo "Extra patch: $arch-$flavor.diff"
	    cp $arch-$flavor.diff $build_dir/
	fi

	[ $arch = i386 ] && arch="%ix86"
	nl=$'\n'
	if [ -n "$p" -o -n "$p" ]; then
	    head="${head}%ifarch $arch$nl"
	    [ -n "$p" ] && head="${head}Provides:     ${p[@]}$nl"
	    [ -n "$o" ] && head="${head}Obsoletes:    ${o[@]}$nl"
	    head="${head}%endif$nl"
	fi
    done
    prov_obs="${head%$'\n'}"

    # If we build this spec file for only one architecture,  the
    # enclosing if is not needed
    if [ $(set -- $archs ; echo $#) -eq 1 ]; then
	prov_obs="$(echo "$prov_obs" | grep -v '%ifarch\|%endif')"
    fi

    # In ExclusiveArch in the spec file, we must specify %ix86 instead
    # of i386.
    archs="$(echo $archs | sed -e 's,i386,%ix86,g')"

    # Generate spec file
    sed -e "s,@NAME@,kernel-$flavor,g" \
	-e "s,@FLAVOR@,$flavor,g" \
	-e "s,@VARIANT@,$VARIANT,g" \
	-e "s,@SRCVERSION@,$SRCVERSION,g" \
	-e "s,@PATCHVERSION@,$PATCHVERSION,g" \
	-e "s,@RPMVERSION@,$RPMVERSION,g" \
	-e "s,@ARCHS@,$archs,g" \
	-e "s,@PROVIDES_OBSOLETES@,${prov_obs//$'\n'/\\n},g" \
	-e "s,@TOLERATE_UNKNOWN_NEW_CONFIG_OPTIONS@,$tolerate_unknown_new_config_options,g" \
	-e "s,@RELEASE@,$RELEASE,g" \
      < rpm/kernel-binary.spec.in \
    > $build_dir/kernel-$flavor.spec
done

install_changes() {
    local changes=$1
    cat kernel-source.changes kernel-source.changes.old > $changes
    chmod 644 $changes
}

for flavor in $flavors ; do
    install_changes $build_dir/kernel-$flavor.changes
done

binary_spec_files=$(
    n=50
    for flavor in syms $flavors ; do
	printf "%-14s%s\n" "Source$n:" "kernel-$flavor.spec"
	n=$[$n+1]
    done
)
binary_spec_files=${binary_spec_files//$'\n'/\\n}

CLEANFILES=()
trap 'if test -n "$CLEANFILES"; then rm -rf "${CLEANFILES[@]}"; fi' EXIT
tmpdir=$(mktemp -dt ${0##*/}.XXXXXX)
CLEANFILES=("${CLEANFILES[@]}" "$tmpdir")

EXTRA_SYMBOLS=$([ -e extra-symbols ] && cat extra-symbols)

# Compute @REQUIRES@ expansion
prepare_source_and_syms() {
    local name=$1
    local head="" nl ARCH_SYMBOLS packages flavor av arch

    requires=

    # Exclude flavors that have a different set of patches: we assume
    # that the user won't change series.conf so much that two flavors
    # that differ at tar-up.sh time will become identical later.
    set -- $EXTRA_SYMBOLS
    case $name in
    (*-rt)
	set -- RT "$@"
	;;
    esac
    scripts/guards "$@" < series.conf > $tmpdir/$name.patches

    for flavor in $flavors; do
	build_archs=
	for arch in $(scripts/arch-symbols --list); do
	    arch_flavor=$(scripts/guards $arch < config.conf | grep "/$flavor$")
	    [ -z "$arch_flavor" ] && continue
	    av="${arch}_${flavor}"
	    [ "$arch" = i386 ] && arch="%ix86"
	    set -- kernel-$flavor $flavor \
		   $(case $flavor in (rt|rt_*) echo RT ;; esac)

	    # The patch selection for kernel-vanilla is a hack.
	    [ $flavor = vanilla ] && continue

	    scripts/guards $* $EXTRA_SYMBOLS < series.conf \
		> $tmpdir/kernel-$av.patches
	    diff -q $tmpdir/{$name,kernel-$av}.patches > /dev/null \
		|| (echo skipping $av ; continue)
	    build_archs="$build_archs $arch"
	done

	build_archs=${build_archs# }

	if [ -n "$build_archs" ]; then
	    nl=$'\n'
	    or='%'
	    head="${head}%ifarch ${build_archs// / || ifarch }$nl"
	    head="${head}Requires: kernel-$flavor-devel = %version-%release$nl"
	    head="${head}%endif$nl"
	fi
    done
    requires="${head//$'\n'/\\n}"
}

# The pre-configured kernel source package
if test -e $build_dir/kernel-default.spec; then
    # if there is no kernel-default, assume that this is a "special"
    # branch (such as slert) with it's own kernel-source
    echo "kernel-source.spec"
    prepare_source_and_syms kernel-syms # compute archs and requires
    sed -e "s,@NAME@,kernel-source,g" \
        -e "s,@VARIANT@,$VARIANT,g" \
        -e "s,@SRCVERSION@,$SRCVERSION,g" \
        -e "s,@PATCHVERSION@,$PATCHVERSION,g" \
        -e "s,@RPMVERSION@,$RPMVERSION,g" \
        -e "s,@BINARY_SPEC_FILES@,$binary_spec_files,g" \
        -e "s,@TOLERATE_UNKNOWN_NEW_CONFIG_OPTIONS@,$tolerate_unknown_new_config_options," \
        -e "s,@RELEASE@,$RELEASE,g" \
      < rpm/kernel-source.spec.in \
    > $build_dir/kernel-source.spec
    install_changes $build_dir/kernel-source.changes

    echo "kernel-syms.spec"
    sed -e "s,@NAME@,kernel-syms,g" \
        -e "s,@VARIANT@,,g" \
        -e "s,@SRCVERSION@,$SRCVERSION,g" \
        -e "s,@PATCHVERSION@,$PATCHVERSION,g" \
        -e "s,@RPMVERSION@,$RPMVERSION,g" \
        -e "s,@REQUIRES@,$requires,g" \
        -e "s,@RELEASE@,$RELEASE,g" \
      < rpm/kernel-syms.spec.in \
    > $build_dir/kernel-syms.spec
    install_changes $build_dir/kernel-syms.changes

    install -m 644                              \
        rpm/kernel-source.rpmlintrc             \
        $build_dir/kernel-source.rpmlintrc
fi

if test -e $build_dir/kernel-rt.spec; then
    echo "kernel-source-rt.spec"
    # workaround
    binary_spec_files=${binary_spec_files/kernel-syms.spec/kernel-syms-rt.spec}
    prepare_source_and_syms kernel-syms-rt # compute archs and requires
    sed -e "s,@NAME@,kernel-source-rt,g" \
        -e "s,@VARIANT@,$VARIANT,g" \
        -e "s,@SRCVERSION@,$SRCVERSION,g" \
        -e "s,@PATCHVERSION@,$PATCHVERSION,g" \
        -e "s,@RPMVERSION@,$RPMVERSION,g" \
        -e "s,@BINARY_SPEC_FILES@,$binary_spec_files,g" \
        -e "s,@TOLERATE_UNKNOWN_NEW_CONFIG_OPTIONS@,$tolerate_unknown_new_config_options," \
        -e "s,@RELEASE@,$RELEASE,g" \
      < rpm/kernel-source.spec.in \
    > $build_dir/kernel-source-rt.spec
    install_changes $build_dir/kernel-source-rt.changes

    echo "kernel-syms-rt.spec"
    sed -e "s,@NAME@,kernel-syms-rt,g" \
        -e "s,@VARIANT@,-rt,g" \
        -e "s,@SRCVERSION@,$SRCVERSION,g" \
        -e "s,@PATCHVERSION@,$PATCHVERSION,g" \
        -e "s,@RPMVERSION@,$RPMVERSION,g" \
        -e "s,@REQUIRES@,$requires,g" \
        -e "s,@RELEASE@,$RELEASE,g" \
      < rpm/kernel-syms.spec.in \
    > $build_dir/kernel-syms-rt.spec
    install_changes $build_dir/kernel-syms-rt.changes

    install -m 644                              \
        rpm/kernel-source.rpmlintrc             \
        $build_dir/kernel-source-rt.rpmlintrc
fi

echo "Copying various files..."
install -m 644					\
	config.conf				\
	supported.conf				\
	rpm/source-pre.sh			\
	rpm/source-post.sh			\
	rpm/pre.sh				\
	rpm/post.sh				\
	rpm/preun.sh				\
	rpm/postun.sh				\
	rpm/module-renames			\
	rpm/kernel-module-subpackage		\
	rpm/macros.kernel-source		\
	doc/README.SUSE				\
	doc/README.KSYMS			\
	$build_dir


if [ -x /work/src/bin/tools/convert_changes_to_rpm_changelog ]; then
    /work/src/bin/tools/convert_changes_to_rpm_changelog kernel-source.changes \
	kernel-source.changes.old >"$build_dir"/rpm_changelog
    for spec in "$build_dir"/*.spec; do
        (echo "%changelog"; cat "$build_dir"/rpm_changelog) >>"$spec"
    done
    rm -f "$build_dir"/rpm_changelog
fi

install -m 755					\
	rpm/find-provides			\
	rpm/config-subst 			\
	rpm/check-for-config-changes		\
	rpm/check-supported-list		\
	rpm/check-build.sh			\
	rpm/modversions				\
	rpm/built-in-where			\
	rpm/symsets.pl                          \
	scripts/guards				\
	scripts/arch-symbols			\
	misc/extract-modaliases			\
	$build_dir

if [ -e extra-symbols ]; then
	install -m 755					\
		extra-symbols				\
		$build_dir
fi

if [ -n "$update_only" ]; then
	exit 0
fi

if [ -r $SRC_FILE ]; then
  LINUX_ORIG_TARBALL=$SRC_FILE
elif [ -r $MIRROR/$SRC_FILE ]; then
  LINUX_ORIG_TARBALL=$MIRROR/$SRC_FILE
elif [ -r $MIRROR/testing/$SRC_FILE ]; then
  LINUX_ORIG_TARBALL=$MIRROR/testing/$SRC_FILE
else
  echo "Cannot find $SRC_FILE."
  exit 1
fi
echo $SRC_FILE
cp $LINUX_ORIG_TARBALL $build_dir

# Usage: stable_tar [-t <timestamp>] [-C <directory] <tarball> <files> ...
# if -t is not given, files must be within a git repository and -C must not be
# used
tar_override_works=
stable_tar() {
    local tarball mtime chdir tar_opts=()

    while test $# -gt 2; do
        case "$1" in
        -t)
            mtime=$2
            shift 2
            ;;
        -C)
            chdir=$2
            shift 2
            ;;
        *)
            break
        esac
    done
    tarball=$1
    shift

    if [ -z "$tar_override_works" ]; then
        if tar --mtime="Tue, 3 Feb 2009 10:52:55 +0100" --owner=nobody \
                    --group=nobody --help >/dev/null; then
            tar_override_works=true
        else
            echo "warning: created tarballs will differ between runs" >&2
            tar_override_works=false
        fi
    fi
    if $tar_override_works; then
        if test -z "$mtime"; then
            mtime="$(git log --pretty=format:%cD "$@" | head -n 1)"
        fi
        tar_opts=(--owner=nobody --group=nobody --mtime="$mtime")
    fi
    (
        if test -n "$chdir"; then
            cd "$chdir"
        fi
        find "$@" \( -type f -o -type d -a -empty \) -print0 | \
            LC_ALL=C sort -z | \
            tar cf - --null -T - "${tar_opts[@]}"
    ) | bzip2 -9 >"$tarball"
}

# The first directory level determines the archive name
all_archives="$(
    echo "$referenced_files" \
    | sed -e 's,/.*,,' \
    | uniq )"
for archive in $all_archives; do
    echo "$archive.tar.bz2"
    case " $IGNORE_ARCHS " in
    *" ${archive#patches.} "*)
	echo "Ignoring $archive..."
	continue ;;
    esac

    files="$( echo "$referenced_files" \
	| sed -ne "\:^${archive//./\\.}/:p" \
	| while read patch; do
	    [ -e "$patch" ] && echo "$patch"
	done)"
    if [ -n "$files" ]; then
	stable_tar $build_dir/$archive.tar.bz2 $files
    fi
done

echo "kabi.tar.bz2"
stable_tar $build_dir/kabi.tar.bz2 kabi

# Create empty dummys for any *.tar.bz2 archive mentioned in the spec file
# not already created: patches.addon is empty by intention; others currently
# may contain no patches.
archives=$(sed -ne 's,^Source[0-9]*:.*[ \t/]\([^/]*\)\.tar\.bz2$,\1,p' \
           $build_dir/*.spec | sort -u)
for archive in $archives; do
    [ "$archive" = "linux-%srcversion" ] && continue
    if ! [ -e $build_dir/$archive.tar.bz2 ]; then
	echo "$archive.tar.bz2 (empty)"
	tmpdir2=$(mktemp -dt ${0##*/}.XXXXXX)
	CLEANFILES=("${CLEANFILES[@]}" "$tmpdir2")
	mkdir -p $tmpdir2/$archive
	touch -d "$(head -n 1 $build_dir/build-source-timestamp)" \
	    $tmpdir2/$archive
	stable_tar -C $tmpdir2 -t "Wed, 01 Apr 2009 12:00:00 +0200" \
	    $build_dir/$archive.tar.bz2 $archive
    fi
done

# Force mbuild to choose build hosts with enough memory available:
echo $((1024*1024)) > $build_dir/minmem
# Force mbuild to choose build hosts with enough disk space available:
echo $((6*1024)) > $build_dir/needed_space_in_mb
if [ -n "$ignore_kabi" ]; then
    ( for i in `seq 0 42` ; do echo "This file named IGNORE-KABI-BADNESS is not empty." ; done ) > $build_dir/IGNORE-KABI-BADNESS
fi
if [ -n "$ignore_unsupported_deps" ]; then
    touch $build_dir/IGNORE-UNSUPPORTED-DEPS
fi
