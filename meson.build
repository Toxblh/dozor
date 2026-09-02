project('dozor', ['vala', 'c'], version: '0.2.0', license: 'GPL-3.0-or-later')

deps = [
  dependency('gtk4'),
  dependency('libadwaita-1'),
  dependency('polkit-agent-1'),
  dependency('polkit-gobject-1'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('json-glib-1.0'),
  dependency('graphene-gobject-1.0'),
  meson.get_compiler('vala').find_library('posix'),
  meson.get_compiler('c').find_library('m', required: false),
]

executable('dozor-agent', ['src/dozor.vala', 'src/collector.vala', 'src/animation.vala', 'src/focus.vala'], dependencies: deps, install: true,
  c_args: ['-DPOLKIT_AGENT_I_KNOW_API_IS_SUBJECT_TO_CHANGE', '-Wno-unused-variable'])


# Юнит собирается из шаблона: путь к бинарю зависит от prefix (пакет -> /usr/bin,
# локальная установка -> ~/.local/bin), поэтому хардкодить его нельзя.
conf = configuration_data()
conf.set('BINDIR', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'dozor.service.in',
  output: 'dozor.service',
  configuration: conf,
  install_dir: get_option('systemd_userunitdir'),
)

extdir = get_option('gnome_extensiondir')
if extdir == ''
  extdir = get_option('prefix') / get_option('datadir') / 'gnome-shell' / 'extensions'
endif
install_subdir('extension/dozor@toxblh.ru', install_dir: extdir)

install_data('ru.toxblh.dozor.policy',
  install_dir: get_option('prefix') / get_option('datadir') / 'polkit-1' / 'actions')

# PAM-хук и гейт отпечатка: ставятся, но в PAM-стек НЕ прописываются
# (это делает dozor-setup вручную, см. спеку).
install_data(['dozor-sudo.sh', 'lid-open.sh'],
  install_dir: get_option('sysconfdir') / 'security',
  install_mode: 'rwxr-xr-x')

install_data('dist/dozor-setup',
  install_dir: get_option('prefix') / get_option('sbindir'),
  install_mode: 'rwxr-xr-x')
