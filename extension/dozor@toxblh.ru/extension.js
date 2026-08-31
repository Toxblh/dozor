// Dozor:
// 1. Отключает встроенный polkit-агент GNOME Shell, чтобы вместо него
//    регистрировался агент Dozor (systemd user unit dozor.service).
//    ComponentManager диффует списки компонентов при смене session mode,
//    поэтому одного _disableComponent хватает: lock/unlock его не возвращает.
//    Компонент создаётся асинхронно при старте Shell — если нас включили
//    раньше, ждём его появления (появился => уже enable()'нут => гасим).
// 2. Экспортирует DBus-метод FocusApp: Shell не пускает посторонних к
//    org.gnome.Shell.FocusApp, а изнутри Shell активировать окно можно.

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const IFACE = `
<node>
  <interface name="ru.toxblh.Dozor">
    <method name="FocusApp">
      <arg type="s" direction="in" name="desktop_id"/>
    </method>
  </interface>
</node>`;

export default class DozorExtension {
    enable() {
        this._retry = 0;
        if (!this._disableShellAgent()) {
            let tries = 0;
            this._retry = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
                if (this._disableShellAgent() || ++tries >= 30) {
                    this._retry = 0;
                    return GLib.SOURCE_REMOVE;
                }
                return GLib.SOURCE_CONTINUE;
            });
        }
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, '/ru/toxblh/Dozor');
    }

    disable() {
        if (this._retry) {
            GLib.Source.remove(this._retry);
            this._retry = 0;
        }
        this._dbus?.unexport();
        this._dbus = null;
        Main.componentManager._enableComponent('polkitAgent');
    }

    _disableShellAgent() {
        if (!Main.componentManager._allComponents.polkitAgent)
            return false;
        Main.componentManager._disableComponent('polkitAgent');
        return true;
    }

    FocusApp(desktopId) {
        Shell.AppSystem.get_default().lookup_app(desktopId)?.activate();
    }
}
