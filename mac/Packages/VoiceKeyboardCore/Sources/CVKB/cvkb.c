// CVKB has no implementation of its own; the actual symbols come from
// libvkb.dylib at link time (Xcode app target supplies -lvkb). This
// translation unit exists only so SwiftPM has something to compile for
// the CVKB target — a header-only target produces no .o file, which
// breaks Xcode's link step when the package is consumed via
// project.yml.
