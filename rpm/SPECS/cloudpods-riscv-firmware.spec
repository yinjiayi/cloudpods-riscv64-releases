Name:           cloudpods-riscv-firmware
Version:        24.03
Release:        1.oe2403sp3
Summary:        openEuler RISC-V UEFI firmware for Cloudpods guests
License:        BSD-2-Clause-Patent
URL:            https://repo.openeuler.org/openEuler-24.03-LTS-SP3/virtual_machine_img/riscv64/
Source0:        RISCV_VIRT_CODE_RVA20.fd
Source1:        RISCV_VIRT_VARS_RVA20.fd
BuildArch:      noarch

%description
The validated RVA20 UEFI code and variables firmware used to boot openEuler
RISC-V virtual machines under Cloudpods and QEMU 10.0.7.

%prep

%build

%install
install -D -m 0644 %{SOURCE0} %{buildroot}/opt/cloud/contrib/OVMF.fd
install -D -m 0644 %{SOURCE1} %{buildroot}/opt/cloud/contrib/OVMF_VARS.fd

%files
%dir /opt/cloud
%dir /opt/cloud/contrib
/opt/cloud/contrib/OVMF.fd
/opt/cloud/contrib/OVMF_VARS.fd

%changelog
* Sun Aug 16 2026 Cloudpods RISC-V release <yinjiayi@users.noreply.github.com> - 24.03-1.oe2403sp3
- Package the openEuler 24.03 LTS SP3 RVA20 virtual-machine firmware.
