%global _empty_manifest_terminate_build 0

Name:           damagebdd
Version:        0.1.0
Release:        1%{?dist}
Summary:        DamageBDD — Behaviour verification at planetary scale (Erlang/OTP relx)

License:        AGPL-3.0-or-later
URL:            https://damagebdd.com
# Preferred: provide a tarball made from a tag (no network during build)
#   git archive --format=tar.gz --prefix=%{name}-%{version}/ -o %{name}-%{version}.tar.gz v%{version}
Source0:        %{name}-%{version}.tar.gz

# Build deps: rebar3 pulls erlang; gcc/make for NIFs if any
BuildRequires:  rebar3
BuildRequires:  erlang
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  systemd
BuildRequires:  tar

# Runtime: we bundle ERTS, so erlang is NOT required at runtime.
Requires(post):    systemd
Requires(preun):   systemd
Requires(postun):  systemd
# If your code uses OpenSSL/GMP at runtime via NIFs, keep these:
Requires:       openssl
Requires:       gmp

Provides:       damagebdd

%description
DamageBDD enables BDD-style behaviour verification and large-scale performance testing.
This RPM packages a self-contained rebar3/relx release (including ERTS) under /usr/libexec/damagebdd
with a launcher at /usr/bin/damagebdd and a systemd unit.

%prep
%setup -q

# Ensure basic config exists if your tarball doesn't ship it
mkdir -p config
[ -f config/sys.config ] || cat > config/sys.config <<'EOF'
[
  {kernel, [{logger, [{handler, default, logger_std_h, #{level => info}}]}]}
].
EOF
[ -f config/vm.args ] || cat > config/vm.args <<'EOF'
-name damagebdd@127.0.0.1
-setcookie damagebdd_cookie
+K true
+A 64
+sbwt none
+swct very_lazy
+P 134217727
+hms 512
+hmmbs 1024
-env ERL_MAX_PORTS 65536
EOF

%build
# Produce a production release with bundled ERTS
rebar3 as prod release

%install
rm -rf "%{buildroot}"

# Release payload
install -d "%{buildroot}%{_libexecdir}/%{name}"
cp -a "_build/prod/rel/%{name}/." "%{buildroot}%{_libexecdir}/%{name}/"

# Path launcher
install -d "%{buildroot}%{_bindir}"
ln -s "%{_libexecdir}/%{name}/bin/%{name}" "%{buildroot}%{_bindir}/%{name}"

# Config lives in /etc (externalized via env in the systemd unit)
install -d "%{buildroot}%{_sysconfdir}/%{name}"
install -m 0644 config/sys.config "%{buildroot}%{_sysconfdir}/%{name}/sys.config"
install -m 0644 config/vm.args    "%{buildroot}%{_sysconfdir}/%{name}/vm.args"

# Systemd unit
install -d "%{buildroot}%{_unitdir}"
install -m 0644 packaging/%{name}.service "%{buildroot}%{_unitdir}/%{name}.service"

# sysusers + tmpfiles
install -d "%{buildroot}%{_sysusersdir}"
install -m 0644 packaging/%{name}.sysusers "%{buildroot}%{_sysusersdir}/%{name}.conf"
install -d "%{buildroot}%{_tmpfilesdir}"
install -m 0644 packaging/%{name}.tmpfiles "%{buildroot}%{_tmpfilesdir}/%{name}.conf"

%pre
# Fallback user creation if sysusers isn't available at install time
getent group %{name} >/dev/null || groupadd -r %{name}
getent passwd %{name} >/dev/null || \
  useradd -r -g %{name} -d /var/lib/%{name} -s /sbin/nologin -c "DamageBDD service user" %{name} || :

%post
# Prefer sysusers + tmpfiles to set up runtime dirs and user/group
if [ -x /usr/lib/systemd/systemd-sysusers ]; then
  /usr/lib/systemd/systemd-sysusers %{_sysusersdir}/%{name}.conf || :
fi
if [ -x /usr/bin/systemd-tmpfiles ]; then
  /usr/bin/systemd-tmpfiles --create %{_tmpfilesdir}/%{name}.conf || :
fi
%systemd_post %{name}.service

%preun
%systemd_preun %{name}.service

%postun
%systemd_postun_with_restart %{name}.service

%files
%license LICENSE* LICENSE .* 2>/dev/null || :
%doc README* CHANGELOG* docs/* 2>/dev/null || :
%config(noreplace) %{_sysconfdir}/%{name}/sys.config
%config(noreplace) %{_sysconfdir}/%{name}/vm.args
%dir %{_sysconfdir}/%{name}

%{_bindir}/%{name}
%{_unitdir}/%{name}.service
%{_sysusersdir}/%{name}.conf
%{_tmpfilesdir}/%{name}.conf

# Own the release tree (recursive; cover typical relx layout depths)
%dir %{_libexecdir}/%{name}
%{_libexecdir}/%{name}/*
%{_libexecdir}/%{name}/*/*
%{_libexecdir}/%{name}/*/*/*
%{_libexecdir}/%{name}/*/*/*/*

# Runtime state (created by tmpfiles; not packaged as files)
%ghost %dir %attr(0755,%{name},%{name}) /var/lib/%{name}
%ghost %dir %attr(0755,%{name},%{name}) /var/log/%{name}

%changelog
* Wed Aug 27 2025 Steven Joseph <you@example.com> - 0.1.0-1
- Initial RPM packaging with bundled ERTS and systemd unit
