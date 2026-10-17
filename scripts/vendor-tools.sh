#!/bin/zsh
# vendor-tools.sh -> app/Helpers, app/Licenses
# Copies mozjpeg (cjpeg, djpeg), pngquant and cwebp from Homebrew together with every
# non-system dylib they load, rewired to load from their own folder (@loader_path),
# so Smoll.app compresses images on a Mac without Homebrew. Rerun after `brew upgrade`.
set -e
cd "$(dirname "$0")/.."
BREW=$(brew --prefix)
for f in mozjpeg pngquant webp; do
    [[ -d $BREW/opt/$f ]] || { echo "Run 'brew install $f' first."; exit 1 }
done

OUT=app/Helpers
LIC=app/Licenses
rm -rf $OUT $LIC
mkdir -p $OUT $LIC

rpaths() { otool -l $1 | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' }

# @rpath/… and @loader_path/… are relative to the real (Cellar) location of the loading file
resolve() {
    local ref=$1 real=$(realpath $2)
    local here=${real:h}
    case $ref in
        @loader_path/*) print -r -- $here/${ref#@loader_path/} ;;
        @rpath/*)
            for rp in $(rpaths $real); do
                local cand=${rp/@loader_path/$here}/${ref#@rpath/}
                [[ -e $cand ]] && { print -r -- $cand; return 0 }
            done
            echo "Can't resolve $ref for $2" >&2
            return 1 ;;
        *) print -r -- $ref ;;
    esac
}

queue=($BREW/opt/mozjpeg/bin/cjpeg $BREW/opt/mozjpeg/bin/djpeg
       $BREW/opt/pngquant/bin/pngquant $BREW/opt/webp/bin/cwebp)
typeset -aU cellars # unique Cellar/<formula>/<version> dirs, for licenses

while (( $#queue )); do
    src=$queue[1]
    shift queue
    name=${src:t}
    [[ -e $OUT/$name ]] && continue
    cp -L $src $OUT/$name
    chmod u+w $OUT/$name
    cellars+=($(realpath $src | sed -E 's|(.*/Cellar/[^/]+/[^/]+)/.*|\1|'))

    for ref in $(otool -L $src | tail -n +2 | awk '{ print $1 }'); do
        [[ $ref == /usr/lib/* || $ref == /System/* ]] && continue
        dep=$(resolve $ref $src)
        [[ ${dep:t} == $name ]] && continue # a dylib's own id
        install_name_tool -change $ref @loader_path/${dep:t} $OUT/$name 2>/dev/null
        queue+=$dep
    done
    [[ $name == *.dylib ]] && install_name_tool -id @loader_path/$name $OUT/$name 2>/dev/null
    for rp in $(rpaths $OUT/$name); do install_name_tool -delete_rpath $rp $OUT/$name 2>/dev/null; done
    codesign --force --sign - $OUT/$name 2>/dev/null
done

# nothing may still point into Homebrew
if otool -L $OUT/* | grep -q "$BREW"; then
    otool -L $OUT/* | grep "$BREW" >&2
    echo "Some files still load from $BREW" >&2
    exit 1
fi

notice=$LIC/NOTICE.txt
print "Smoll.app/Contents/Helpers contains these open-source programs and libraries, unmodified,
taken from Homebrew builds. Smoll runs them as separate programs. Each one's license is in
the folder named after it; source code is at the URL listed.\n" > $notice
for cellar in $cellars; do
    formula=${cellar:h:t} version=${cellar:t}
    mkdir -p $LIC/$formula
    for f in $cellar/(LICENSE|COPYING|COPYRIGHT|NOTICE|PATENTS|AUTHORS|README.ijg)*(N.); do cp $f $LIC/$formula/; done
    info=$(brew info --json=v2 $formula)
    license=$(print -r -- $info | plutil -extract formulae.0.license raw -o - - 2>/dev/null || echo "see folder")
    url=$(print -r -- $info | plutil -extract formulae.0.urls.stable.url raw -o - -)
    print "$formula $version — $license\n  source: $url" >> $notice
done
print "\npngquant is GPL-3.0: you may get its complete source code at the URL above;
Smoll's own code is not derived from it." >> $notice

echo "Vendored into $OUT ($(du -sh $OUT | cut -f1)):"
ls $OUT
