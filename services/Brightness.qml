pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.components.misc
import qs.services

Singleton {
    id: root

    property list<var> ddcMonitors: []
    readonly property var ddcMonitorMap: {
        const map = {};
        for (const m of ddcMonitors)
            map[m.connector] = m;
        return map;
    }
    readonly property list<Monitor> monitors: variants.instances
    property bool appleDisplayPresent: false

    function getMonitorForScreen(screen: ShellScreen): var {
        return monitors.find(m => m.modelData === screen);
    }

    function getMonitor(query: string): var {
        if (query === "active") {
            return monitors.find(m => Hypr.monitorFor(m.modelData)?.focused);
        }

        if (query.startsWith("model:")) {
            const model = query.slice(6);
            return monitors.find(m => m.modelData.model === model);
        }

        if (query.startsWith("serial:")) {
            const serial = query.slice(7);
            return monitors.find(m => m.modelData.serialNumber === serial);
        }

        if (query.startsWith("id:")) {
            const id = parseInt(query.slice(3), 10);
            return monitors.find(m => Hypr.monitorFor(m.modelData)?.id === id);
        }

        return monitors.find(m => m.modelData.name === query);
    }

    function increaseBrightness(): void {
        const monitor = getMonitor("active");
        if (monitor)
            monitor.setBrightness(monitor.brightness + GlobalConfig.services.brightnessIncrement);
    }

    function decreaseBrightness(): void {
        const monitor = getMonitor("active");
        if (monitor)
            monitor.setBrightness(monitor.brightness - GlobalConfig.services.brightnessIncrement);
    }

    onMonitorsChanged: {
        ddcMonitors = [];
        ddcProc.running = true;
    }

    Variants {
        id: variants

        model: Quickshell.screens // Don't respect excluded screens cause ipc

        Monitor {}
    }

    Process {
        running: true
        command: ["sh", "-c", "asdbctl get"] // To avoid warnings if asdbctl is not installed
        stdout: StdioCollector {
            onStreamFinished: root.appleDisplayPresent = text.trim().length > 0
        }
    }

    Process {
        id: ddcProc

        command: ["ddcutil", "detect", "--brief"]
        stdout: StdioCollector {
            onStreamFinished: root.ddcMonitors = text.trim().split("\n\n").filter(d => d.startsWith("Display ")).map(d => ({
                        busNum: d.match(/I2C bus:[ ]*\/dev\/i2c-([0-9]+)/)[1],
                        connector: d.match(/DRM connector:\s+(.*)/)[1].replace(/^card\d+-/, "") // strip "card1-"
                    }))
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "brightnessUp"
        description: "Increase brightness"
        onPressed: root.increaseBrightness()
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "brightnessDown"
        description: "Decrease brightness"
        onPressed: root.decreaseBrightness()
    }

    IpcHandler {
        function get(): real {
            return getFor("active");
        }

        // Allows searching by active/model/serial/id/name
        function getFor(query: string): real {
            return root.getMonitor(query)?.brightness ?? -1;
        }

        function set(value: string): string {
            return setFor("active", value);
        }

        // Handles brightness value like brightnessctl: 0.1, +0.1, 0.1-, 10%, +10%, 10%-
        function setFor(query: string, value: string): string {
            const monitor = root.getMonitor(query);
            if (!monitor)
                return "Invalid monitor: " + query;

            let targetBrightness;
            if (value.endsWith("%-")) {
                const percent = parseFloat(value.slice(0, -2));
                targetBrightness = monitor.brightness - (percent / 100);
            } else if (value.startsWith("+") && value.endsWith("%")) {
                const percent = parseFloat(value.slice(1, -1));
                targetBrightness = monitor.brightness + (percent / 100);
            } else if (value.endsWith("%")) {
                const percent = parseFloat(value.slice(0, -1));
                targetBrightness = percent / 100;
            } else if (value.startsWith("+")) {
                const increment = parseFloat(value.slice(1));
                targetBrightness = monitor.brightness + increment;
            } else if (value.endsWith("-")) {
                const decrement = parseFloat(value.slice(0, -1));
                targetBrightness = monitor.brightness - decrement;
            } else if (value.includes("%") || value.includes("-") || value.includes("+")) {
                return `Invalid brightness format: ${value}\nExpected: 0.1, +0.1, 0.1-, 10%, +10%, 10%-`;
            } else {
                targetBrightness = parseFloat(value);
            }

            if (isNaN(targetBrightness))
                return `Failed to parse value: ${value}\nExpected: 0.1, +0.1, 0.1-, 10%, +10%, 10%-`;

            monitor.setBrightness(targetBrightness);

            return `Set monitor ${monitor.modelData.name} brightness to ${+monitor.brightness.toFixed(2)}`;
        }

        target: "brightness"
    }

    component Monitor: QtObject {
        id: monitor

        required property ShellScreen modelData
        readonly property var ddcInfo: root.ddcMonitorMap[modelData.name] ?? null
        readonly property bool isDdc: ddcInfo !== null
        readonly property string busNum: ddcInfo?.busNum ?? ""
        readonly property bool isAppleDisplay: root.appleDisplayPresent && modelData.model.startsWith("StudioDisplay")
        property real brightness
        property real queuedBrightness: NaN
        property string backlightDevice: ""
        property int maxBrightness: 0
        property bool ready: false
        property bool pendingBacklightReload: false
        property bool pendingSyncReload: false
        property real lastInternalWriteTime: 0

        readonly property Process initProc: Process {
            stdout: StdioCollector {
                onStreamFinished: {
                    if (monitor.isAppleDisplay) {
                        monitor.backlightDevice = "";
                        monitor.maxBrightness = 0;
                        const val = parseInt(text.trim(), 10);
                        if (!isNaN(val))
                            monitor.brightness = val / 101;
                    } else if (monitor.isDdc) {
                        monitor.backlightDevice = "";
                        monitor.maxBrightness = 0;
                        const [, , , cur, max] = text.trim().split(" ");
                        const curNum = parseInt(cur, 10);
                        const maxNum = parseInt(max, 10);
                        if (!isNaN(curNum) && !isNaN(maxNum) && maxNum > 0)
                            monitor.brightness = curNum / maxNum;
                    } else {
                        const [device, , cur, , max] = text.trim().split(",");
                        const curNum = parseInt(cur, 10);
                        const maxNum = parseInt(max, 10);
                        if (device && !isNaN(curNum) && !isNaN(maxNum) && maxNum > 0) {
                            monitor.maxBrightness = maxNum;
                            monitor.backlightDevice = device;
                            monitor.brightness = Math.max(0, Math.min(1, curNum / maxNum));
                        } else {
                            monitor.backlightDevice = "";
                            monitor.maxBrightness = 0;
                        }
                    }
                    monitor.ready = true;
                }
            }
        }

        readonly property FileView backlightWatcher: FileView {
            path: monitor.backlightDevice && !monitor.isDdc && !monitor.isAppleDisplay ? `/sys/class/backlight/${monitor.backlightDevice}/brightness` : ""
            watchChanges: path.length > 0

            onFileChanged: {
                monitor.pendingBacklightReload = true;
                reload();
            }

            onLoaded: {
                const fromFileChange = monitor.pendingBacklightReload;
                const fromSync = monitor.pendingSyncReload;
                monitor.pendingBacklightReload = false;
                monitor.pendingSyncReload = false;

                if (!fromFileChange && !fromSync)
                    return;

                // Ignore intermediate sysfs echoes while Caelestia is driving brightness;
                // syncTimer reconciles the settled hardware value afterward.
                if (Date.now() - monitor.lastInternalWriteTime < 150)
                    return;

                const raw = parseInt(text().trim(), 10);
                if (isNaN(raw) || monitor.maxBrightness <= 0)
                    return;

                const next = Math.max(0, Math.min(1, raw / monitor.maxBrightness));
                if (Math.round(next * 100) !== Math.round(monitor.brightness * 100)) {
                    monitor.brightness = next;
                } else if (fromFileChange && monitor.ready) {
                    monitor.externalBrightnessChanged();
                }
            }
        }

        readonly property Timer timer: Timer {
            interval: 500
            onTriggered: {
                if (!isNaN(monitor.queuedBrightness)) {
                    monitor.setBrightness(monitor.queuedBrightness);
                    monitor.queuedBrightness = NaN;
                }
            }
        }

        readonly property Timer syncTimer: Timer {
            interval: 200
            onTriggered: {
                if (monitor.backlightWatcher.path.length > 0) {
                    monitor.pendingSyncReload = true;
                    monitor.backlightWatcher.reload();
                }
            }
        }

        signal externalBrightnessChanged

        function setBrightness(value: real): void {
            value = Math.max(0, Math.min(1, value));
            const rounded = Math.round(value * 100);
            if (Math.round(brightness * 100) === rounded)
                return;

            if (isDdc && timer.running) {
                queuedBrightness = value;
                return;
            }

            brightness = value;

            if (isAppleDisplay) {
                Quickshell.execDetached(["asdbctl", "set", rounded]);
            } else if (isDdc) {
                Quickshell.execDetached(["ddcutil", "-b", busNum, "setvcp", "10", rounded]);
                timer.restart();
            } else {
                lastInternalWriteTime = Date.now();
                const cmd = backlightDevice ? ["brightnessctl", "-d", backlightDevice, "s", `${rounded}%`] : ["brightnessctl", "s", `${rounded}%`];
                Quickshell.execDetached(cmd);
                syncTimer.restart();
            }
        }

        function initBrightness(): void {
            if (isAppleDisplay)
                initProc.command = ["asdbctl", "get"];
            else if (isDdc)
                initProc.command = ["ddcutil", "-b", busNum, "getvcp", "10", "--brief"];
            else
                initProc.command = ["brightnessctl", "-m", "-c", "backlight", "info"];

            initProc.running = true;
        }

        onBusNumChanged: initBrightness()
        onIsAppleDisplayChanged: initBrightness()
        Component.onCompleted: initBrightness()
    }
}
