%global debug_package %{nil}
%global __strip /bin/true

Name:           cloudpods-executor
Version:        4.0.3
Release:        1.oe2403sp3
Summary:        Cloudpods privileged executor for openEuler RISC-V
License:        Apache-2.0
URL:            https://github.com/yunionio/cloudpods
Source0:        executor-server
Source1:        cloudpods-executor.service
Source2:        climc
BuildArch:      riscv64
Requires:       systemd
Provides:       yunion-climc = %{version}

%description
Privileged command executor and climc client used by ocboot and the Cloudpods
host service on openEuler 24.03 LTS SP3 riscv64.

%prep

%build

%install
install -D -m 0755 %{SOURCE0} \
    %{buildroot}/usr/local/libexec/cloudpods/executor-server
install -D -m 0644 %{SOURCE1} \
    %{buildroot}%{_unitdir}/cloudpods-executor.service
install -D -m 0755 %{SOURCE2} \
    %{buildroot}/opt/yunion/bin/climc

%post
%systemd_post cloudpods-executor.service

%preun
%systemd_preun cloudpods-executor.service

%postun
%systemd_postun_with_restart cloudpods-executor.service

%files
/usr/local/libexec/cloudpods/executor-server
/opt/yunion/bin/climc
%{_unitdir}/cloudpods-executor.service

%changelog
* Sun Aug 16 2026 Cloudpods RISC-V release <yinjiayi@users.noreply.github.com> - 4.0.3-1.oe2403sp3
- Package the statically linked executor-server and climc used by ocboot on riscv64.
