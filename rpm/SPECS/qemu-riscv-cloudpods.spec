%global debug_package %{nil}
%global __strip /bin/true

Name:           qemu-riscv-cloudpods
Version:        10.0.7
Release:        3.oe2403sp3
Summary:        QEMU RISC-V system emulator for Cloudpods on openEuler
License:        GPL-2.0-or-later
URL:            https://www.qemu.org/
Source0:        qemu-10.0.7-openEuler24.03-riscv64.tar.xz
Source1:        qemu-system-riscv64-cloudpods
BuildArch:      riscv64

Provides:       bundled(qemu) = %{version}
Provides:       qemu-system-riscv64 = %{version}

%description
QEMU 10.0.7 built for the riscv64 KVM host used by Cloudpods on
openEuler 24.03 LTS SP3.  It is installed below /usr/local/qemu-10.0.7
so the operating system QEMU package remains untouched.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
tar --no-same-owner -xJf %{SOURCE0} -C %{buildroot}
test -x %{buildroot}/usr/local/qemu-10.0.7/bin/qemu-system-riscv64
mv \
    %{buildroot}/usr/local/qemu-10.0.7/bin/qemu-system-riscv64 \
    %{buildroot}/usr/local/qemu-10.0.7/bin/qemu-system-riscv64.real
install -m 0755 \
    %{SOURCE1} \
    %{buildroot}/usr/local/qemu-10.0.7/bin/qemu-system-riscv64

%files
%defattr(-,root,root,-)
/usr/local/qemu-10.0.7

%changelog
* Sun Aug 16 2026 Cloudpods RISC-V deployment <root@localhost> - 10.0.7-3.oe2403sp3
- Fall back to userspace virtio tap networking when the host kernel omits vhost_net.
- Preserve vhost acceleration automatically when /dev/vhost-net is available.

* Sat Aug 15 2026 Cloudpods RISC-V deployment <root@localhost> - 10.0.7-2.oe2403sp3
- Default RISC-V guests to acpi=off as required by the official openEuler image script.
- Preserve explicit ACPI settings supplied by callers.

* Sat Aug 15 2026 Cloudpods RISC-V deployment <root@localhost> - 10.0.7-1.oe2403sp3
- Package the verified QEMU 10.0.7 RISC-V KVM build for Cloudpods.
