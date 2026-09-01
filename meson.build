project('dozor', ['vala', 'c'], version: '0.2.0', license: 'GPL-3.0-or-later')

deps = [
  dependency('gtk4'),
  dependency('libadwaita-1'),
  dependency('polkit-agent-1'),
  dependency('polkit-gobject-1'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  meson.get_compiler('vala').find_library('posix'),
]

executable('dozor-agent', ['src/dozor.vala', 'src/collector.vala'], dependencies: deps, install: true,
  c_args: ['-DPOLKIT_AGENT_I_KNOW_API_IS_SUBJECT_TO_CHANGE', '-Wno-unused-variable'])

