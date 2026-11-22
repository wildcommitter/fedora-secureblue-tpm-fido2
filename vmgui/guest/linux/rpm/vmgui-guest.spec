# vmgui guest addon for Fedora-family VMs: built by vmgui/guest/build.sh.
Name:           vmgui-guest
Version:        %{vmgui_version}
Release:        1%{?dist}
Summary:        Show this VM's windows on the host's scroll session (vmgui)
License:        LicenseRef-scroll-secure-unlicensed
BuildArch:      noarch
Source0:        vmgui-guest-linux.tar
Requires:       waypipe
Requires:       python3
Requires(post): systemd

%description
Runs waypipe server on a vmgui display in the user session and forwards each
app over vsock to the host, where vmgui-host draws it framed in the VM's color.

%package wlroots
Summary:        vmgui: native Wayland apps default to the vmgui display
Requires:       %{name} = %{version}-%{release}

%description wlroots
environment.d defaults so Wayland apps (GTK, Qt, SDL, Firefox) use the vmgui
display, which waypipe forwards to the host.

%package xorg
Summary:        vmgui: X11 apps through xwayland-satellite
Requires:       %{name} = %{version}-%{release}
Requires:       xwayland-satellite

%description xorg
xwayland-satellite on the vmgui display as X server :7, so X11 apps show up on
the host as ordinary windows.

%prep
%setup -q -c

%install
cp -a common/usr wlroots/usr xorg/usr %{buildroot}/

%post
systemctl --global enable vmgui-guest.service >/dev/null 2>&1 || :

%preun
[ $1 -eq 0 ] && systemctl --global disable vmgui-guest.service >/dev/null 2>&1 || :

%post xorg
systemctl --global enable vmgui-xorg.service >/dev/null 2>&1 || :

%preun xorg
[ $1 -eq 0 ] && systemctl --global disable vmgui-xorg.service >/dev/null 2>&1 || :

%files
/usr/libexec/vmgui/vmgui-guest
/usr/lib/systemd/user/vmgui-guest.service

%files wlroots
/usr/lib/environment.d/60-vmgui.conf

%files xorg
/usr/lib/systemd/user/vmgui-xorg.service
/usr/lib/environment.d/61-vmgui-xorg.conf
