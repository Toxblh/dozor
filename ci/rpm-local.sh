#!/bin/sh
# Собрать RPM локально в контейнере ALT тем же способом, что и CI, но без
# hasher (вложенная контейнеризация в rootless podman не работает).
# Проверяет главное: спеку, BuildRequires и что Vala реально компилируется.
# Использование: ci/rpm-local.sh [sisyphus|p11]   (результат в ./out-rpm/)
set -e
cd "$(dirname "$0")/.."
BRANCH="${1:-sisyphus}"
mkdir -p out-rpm
podman run --rm -i -v "$PWD":/work:Z -w /work "registry.altlinux.org/alt/alt:$BRANCH" sh -eux - <<'EOF'
set -euo pipefail
apt-get update -qq
apt-get install -y -qq rpm-build git

# BuildRequires берём прямо из спеки, чтобы список не разъезжался
brs=$(sed -n 's/^BuildRequires: *//p' /work/dozor.spec | tr '\n' ' ')
echo "BuildRequires: $brs"
apt-get install -y -qq $brs

# ALT запрещает сборку от root; builder пишет только в /tmp
useradd -m builder
cp -a /work /tmp/src
chown -R builder: /tmp/src

runuser -u builder -- sh -eux -c '
    set -euo pipefail
    ver=$(sed -n "s/^Version: *//p" /tmp/src/dozor.spec)
    mkdir -p /tmp/rpmbuild/SOURCES /tmp/rpmbuild/SPECS
    cd /tmp/src
    git config --global --add safe.directory /tmp/src
    tar --exclude=.git --exclude=build --exclude=out-rpm --exclude=out-als \
        --transform "s,^\.,dozor-$ver," -czf /tmp/rpmbuild/SOURCES/dozor-$ver.tar .
    cp dozor.spec /tmp/rpmbuild/SPECS/
    rpmbuild -ba --define "_topdir /tmp/rpmbuild" /tmp/rpmbuild/SPECS/dozor.spec
'
install -d /work/out-rpm
find /tmp/rpmbuild/RPMS /tmp/rpmbuild/SRPMS -name '*.rpm' -exec cp -v {} /work/out-rpm/ \;
EOF
echo; ls -la out-rpm/
