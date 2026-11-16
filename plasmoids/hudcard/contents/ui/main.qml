import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore

// HUD Card: a square desktop card that cycles through stock and account pages.
Item {
    id: root

    Plasmoid.preferredRepresentation: Plasmoid.fullRepresentation
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    Layout.minimumWidth: 140
    Layout.minimumHeight: 140
    Layout.preferredWidth: 192
    Layout.preferredHeight: 256
    Layout.maximumWidth: 600
    Layout.maximumHeight: 600

    // ---- style -------------------------------------------------------------
    readonly property color stripColor: Qt.rgba(0, 0, 0, 0.78)
    readonly property color textColor: "#F2F2F2"
    readonly property color upColor: "#3DDC84"
    readonly property color downColor: "#FF5252"
    readonly property color mutedColor: "#B0B0B0"
    readonly property color accentColor: "#2F8CFF"   // electric blue: forecasts, badges
    readonly property color warnColor: "#FFB74D"
    readonly property string sans: "Noto Sans, DejaVu Sans, sans-serif"
    readonly property string mono: "Noto Sans Mono, DejaVu Sans Mono, monospace"
    readonly property real u: Math.min(width, height)
    readonly property real pad: Math.max(5, u * 0.05)
    readonly property int fontTiny: Math.max(8, Math.round(u * 0.055))
    readonly property int fontSmall: Math.max(8, Math.round(u * 0.062))
    readonly property int fontMid: Math.max(9, Math.round(u * 0.075))
    readonly property int fontName: Math.max(8, Math.round(u * 0.058))
    readonly property int fontSym: Math.max(10, Math.round(u * 0.09))
    readonly property int fontPrice: Math.max(14, Math.round(u * 0.16))
    readonly property int fontChg: Math.max(9, Math.round(u * 0.07))

    // ---- state -------------------------------------------------------------
    property var stocks: ({})
    property var accountsDoc: null
    property string updatedAt: ""
    property bool marketHours: false
    property string statusMessage: i18n("Loading…")
    property int pageIndex: 0
    property int dataVersion: 0
    property bool hovered: hover.hovered
    property string lastCommand: ""

    readonly property var pages: parsePages(plasmoid.configuration.items)
    readonly property var page: pages.length ? pages[Math.min(pageIndex, pages.length - 1)] : null
    readonly property var stock: (page && page.kind === "stock") ? (stocks[page.symbol] || null) : null
    readonly property var account: (page && page.kind === "account") ? findAccount(page.id) : null

    function parsePages(text) {
        var out = [];
        var parts = String(text || "").split(/[\n,;]+/);
        for (var i = 0; i < parts.length; i++) {
            var raw = parts[i].trim();
            if (!raw || raw.charAt(0) === "#") continue;
            if (raw.charAt(0) === "@") {
                out.push({ kind: "account", id: raw.substring(1).trim() });
            } else {
                var bits = raw.split("|");
                var sym = bits[0].trim().toUpperCase().replace(/[^A-Z0-9.^_=-]/g, "");
                if (sym) out.push({ kind: "stock", symbol: sym, query: (bits[1] || "").trim() });
            }
        }
        if (!out.length) out.push({ kind: "stock", symbol: "AAPL", query: "" });
        return out;
    }
    function findAccount(id) {
        var list = (accountsDoc && accountsDoc.accounts) ? accountsDoc.accounts : [];
        for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i];
        return null;
    }

    // ---- formatting ----------------------------------------------------------
    function money(v) {
        if (v === undefined || v === null || v === "") return "—";
        var n = Number(v);
        if (isNaN(n)) return "—";
        return n.toLocaleString(Qt.locale("en_US"), "f", Math.abs(n) >= 1 || n === 0 ? 2 : 4);
    }
    function dollars(v, decimals) {
        if (v === undefined || v === null || v === "") return "—";
        var n = Number(v);
        if (isNaN(n)) return "—";
        var d = decimals === undefined ? 2 : decimals;
        return (n < 0 ? "−$" : "$") + Math.abs(n).toLocaleString(Qt.locale("en_US"), "f", d);
    }
    function signed(v, suffix) {
        if (v === undefined || v === null || v === "") return "—";
        var n = Number(v);
        if (isNaN(n)) return "—";
        var s = (n > 0 ? "+" : (n < 0 ? "−" : "")) + Math.abs(n).toFixed(2);
        return suffix ? s + suffix : s;
    }
    function signedDollars(v) {
        if (v === undefined || v === null) return "—";
        var n = Number(v);
        var d = Math.abs(n) >= 1000 ? 0 : 2;
        return (n > 0 ? "+" : (n < 0 ? "−" : "")) + "$" + Math.abs(n).toLocaleString(Qt.locale("en_US"), "f", d);
    }
    function shortDate(iso) {
        if (!iso) return "";
        var p = String(iso).split("-");
        var dt = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][dt.getDay()] + " " + Number(p[1]) + "/" + Number(p[2]);
    }
    function badgeFor(acc) {
        var t = acc ? String(acc.type) : "";
        if (t === "checking") return "CHK";
        if (t === "savings") return "SAV";
        if (t === "retirement" || t === "401k" || t === "ira") return "RET";
        if (t === "hsa") return "HSA";
        return t.substring(0, 3).toUpperCase();
    }
    function accountTitle(acc) {
        if (!acc) return "";
        return acc.name + (acc.mask ? "  ··" + acc.mask : "");
    }

    // ---- data ------------------------------------------------------------------
    function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
    function scriptPath() {
        var p = String(Qt.resolvedUrl("../code/fetch.py"));
        if (p.indexOf("file://") === 0) p = decodeURIComponent(p.substring(7));
        return p;
    }
    function accountsPath() {
        var p = String(plasmoid.configuration.accountsFile || "").trim();
        return p.length ? p : "~/.local/share/controllimit-hud/accounts.json";
    }
    function fetchData() {
        var cmd = "/usr/bin/python3 " + shellQuote(scriptPath());
        var needAccounts = false;
        for (var i = 0; i < pages.length; i++) {
            if (pages[i].kind === "stock")
                cmd += " --stock " + shellQuote(pages[i].symbol + (pages[i].query ? "|" + pages[i].query : ""));
            else needAccounts = true;
        }
        if (needAccounts) cmd += " --accounts " + shellQuote(accountsPath());
        lastCommand = cmd;
        fetcher.exec(cmd);
    }
    function applyPayload(obj) {
        stocks = obj.stocks || {};
        accountsDoc = obj.accounts || null;
        updatedAt = obj.updatedAt || "";
        marketHours = !!obj.marketHours;
        statusMessage = "";
        refreshTimer.interval = currentInterval();
        dataVersion++;
    }
    function currentInterval() {
        var market = 1000 * Math.max(15, plasmoid.configuration.refreshMarketSeconds || 60);
        var off = 1000 * Math.max(60, plasmoid.configuration.refreshOffhoursSeconds || 300);
        return marketHours ? market : off;
    }
    function step(delta) {
        if (pages.length < 2) return;
        pageIndex = (pageIndex + delta + pages.length) % pages.length;
        cycleTimer.restart();
    }

    PlasmaCore.DataSource {
        id: fetcher
        engine: "executable"
        connectedSources: []
        onNewData: {
            var stdout = data["stdout"] || "";
            var code = data["exit code"];
            disconnectSource(sourceName);
            if (sourceName !== root.lastCommand) return;   // stale result from an older page list
            if (code !== 0 && !stdout) {
                statusMessage = i18n("Update failed — will retry");
                console.log("hudcard fetch failed:", code, data["stderr"] || "");
                return;
            }
            try { applyPayload(JSON.parse(stdout)); }
            catch (e) {
                statusMessage = i18n("Update failed — will retry");
                console.log("hudcard parse failed:", e);
            }
        }
        function exec(cmd) { connectSource(cmd); }
    }

    Timer { id: refreshTimer; interval: 60000; repeat: true; running: true; onTriggered: fetchData() }
    Timer {
        id: cycleTimer
        interval: 1000 * Math.max(3, plasmoid.configuration.cycleSeconds || 10)
        repeat: true
        running: root.pages.length > 1 && (plasmoid.configuration.cycleSeconds || 0) > 0
                 && !(plasmoid.configuration.pauseOnHover && root.hovered)
        onTriggered: root.step(1)
    }

    Connections {
        target: plasmoid.configuration
        function onItemsChanged() { root.pageIndex = 0; fetchData(); }
        function onAccountsFileChanged() { fetchData(); }
        function onRefreshMarketSecondsChanged() { refreshTimer.interval = currentInterval(); }
        function onRefreshOffhoursSecondsChanged() { refreshTimer.interval = currentInterval(); }
    }
    onPageChanged: fade.restart()
    Component.onCompleted: fetchData()

    // ---- chart helpers (Qt 5 Canvas has no setLineDash) --------------------------
    function dashTo(ctx, x1, y1, x2, y2, dash, gap) {
        var dx = x2 - x1, dy = y2 - y1, len = Math.sqrt(dx * dx + dy * dy);
        if (len <= 0) return;
        var ux = dx / len, uy = dy / len, pos = 0;
        while (pos < len) {
            var e = Math.min(pos + dash, len);
            ctx.moveTo(x1 + ux * pos, y1 + uy * pos);
            ctx.lineTo(x1 + ux * e, y1 + uy * e);
            pos = e + gap;
        }
    }
    // Draws history (solid) and optional forecast (dashed) on one time axis.
    function drawSeries(cv, hist, fc, lowPoint) {
        var ctx = cv.getContext("2d");
        ctx.reset();
        ctx.clearRect(0, 0, cv.width, cv.height);
        hist = hist || []; fc = fc || [];
        var all = hist.concat(fc);
        if (all.length < 2) return;
        var min = Number(all[0].v), max = min;
        for (var i = 1; i < all.length; i++) {
            var v = Number(all[i].v);
            if (v < min) min = v;
            if (v > max) max = v;
        }
        var span = (max - min) || Math.max(1, Math.abs(max) * 0.01);
        var padY = 3, w = cv.width - 1, h = cv.height;
        var n = hist.length + Math.max(0, fc.length - 1);
        function X(idx) { return n <= 1 ? w / 2 : idx * w / (n - 1); }
        function Y(val) { return padY + (1 - (Number(val) - min) / span) * (h - padY * 2); }
        // zero line when the range crosses below zero
        if (min < 0 && max > 0) {
            ctx.strokeStyle = Qt.rgba(1, 0.32, 0.32, 0.6);
            ctx.lineWidth = 1;
            ctx.beginPath(); dashTo(ctx, 0, Y(0), w, Y(0), 3, 3); ctx.stroke();
        }
        var up = hist.length < 2 || Number(hist[hist.length - 1].v) >= Number(hist[0].v);
        ctx.lineWidth = Math.max(1.2, root.u * 0.009);
        ctx.strokeStyle = up ? root.upColor : root.downColor;
        ctx.beginPath();
        for (var j = 0; j < hist.length; j++) {
            if (j === 0) ctx.moveTo(X(j), Y(hist[j].v)); else ctx.lineTo(X(j), Y(hist[j].v));
        }
        ctx.stroke();
        if (fc.length > 1) {
            var base = Math.max(0, hist.length - 1);
            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.22);
            ctx.lineWidth = 1;
            ctx.beginPath(); ctx.moveTo(X(base) + 0.5, 0); ctx.lineTo(X(base) + 0.5, h); ctx.stroke();
            ctx.strokeStyle = root.accentColor;
            ctx.lineWidth = Math.max(1.2, root.u * 0.009);
            ctx.beginPath();
            for (var k = 1; k < fc.length; k++)
                dashTo(ctx, X(base + k - 1), Y(fc[k - 1].v), X(base + k), Y(fc[k].v), 4, 3);
            ctx.stroke();
            if (lowPoint) {
                for (var m = 0; m < fc.length; m++) {
                    if (fc[m].d === lowPoint.d) {
                        ctx.fillStyle = Number(lowPoint.v) < 0 ? root.downColor : root.warnColor;
                        ctx.beginPath();
                        ctx.arc(X(base + m), Y(fc[m].v), Math.max(2, root.u * 0.016), 0, Math.PI * 2);
                        ctx.fill();
                        break;
                    }
                }
            }
        }
        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.12);
        ctx.lineWidth = 1;
        ctx.beginPath(); ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5); ctx.stroke();
    }

    // ---- view -------------------------------------------------------------------
    Rectangle {
        id: card
        anchors.fill: parent
        color: root.stripColor
        radius: Math.max(4, root.u * 0.05)
        border.color: Qt.rgba(1, 1, 1, 0.12)
        border.width: 1

        HoverHandler { id: hover }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onClicked: root.step(1)
            onWheel: root.step(wheel.angleDelta.y < 0 ? 1 : -1)
        }

        Loader {
            id: pageLoader
            clip: true
            anchors.fill: parent
            anchors.margins: root.pad
            anchors.bottomMargin: root.pad + footer.height + 2
            sourceComponent: !root.page ? null
                           : root.page.kind === "stock" ? stockPage
                           : !root.account ? missingPage
                           : (root.account.type === "checking" || root.account.type === "savings" || root.account.type === "cash") ? cashPage
                           : root.account.type === "hsa" ? hsaPage : retirementPage
            NumberAnimation { id: fade; target: pageLoader; property: "opacity"; from: 0.15; to: 1; duration: 350 }
        }

        Item {
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: root.pad
            height: Math.max(9, root.fontTiny)
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - dots.width - 4
                elide: Text.ElideRight
                color: root.mutedColor
                font.pixelSize: Math.max(7, root.fontTiny - 1)
                font.family: root.sans
                text: root.statusMessage ? root.statusMessage
                    : (root.page && root.page.kind === "account" && root.accountsDoc && root.accountsDoc.generated)
                      ? i18n("As of %1", String(root.accountsDoc.generated).substring(5, 16).replace("T", " "))
                      : (root.updatedAt ? i18n("Updated %1", root.updatedAt) : "")
            }
            Row {
                id: dots
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Math.max(3, root.u * 0.018)
                visible: root.pages.length > 1
                Repeater {
                    model: root.pages.length
                    Rectangle {
                        width: Math.max(4, root.u * 0.026); height: width; radius: width / 2
                        color: index === root.pageIndex ? root.accentColor : Qt.rgba(1, 1, 1, 0.28)
                        MouseArea { anchors.fill: parent; anchors.margins: -3; onClicked: { root.pageIndex = index; cycleTimer.restart(); } }
                    }
                }
            }
        }
    }

    // Shared header row: bold tag + muted name.
    component Header: Row {
        property string tag: ""
        property string title: ""
        property color tagColor: root.textColor
        width: parent ? parent.width : 0
        spacing: Math.max(4, root.u * 0.03)
        Text { id: tagText; text: tag; color: tagColor; font.pixelSize: root.fontSym; font.bold: true; font.family: root.sans }
        Text {
            width: Math.max(10, parent.width - tagText.width - parent.spacing)
            text: title; color: root.mutedColor; font.pixelSize: root.fontName; font.family: root.sans
            elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter
        }
    }
    component BigNumber: Text {
        width: parent ? parent.width : 0
        height: root.fontPrice * 1.2
        color: root.textColor
        font.pixelSize: root.fontPrice
        font.bold: true
        font.family: root.mono
        fontSizeMode: Text.HorizontalFit
        minimumPixelSize: Math.max(10, root.fontPrice * 0.55)
        verticalAlignment: Text.AlignVCenter
    }
    component Stat: Row {
        property string label: ""
        property string value: ""
        property color valueColor: root.textColor
        width: parent ? parent.width : 0
        spacing: 4
        Text {
            width: Math.max(10, parent.width - statValue.width - 4)
            text: label; color: root.mutedColor; font.pixelSize: root.fontTiny; font.family: root.sans
            elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: statValue
            width: Math.min(implicitWidth, parent.width * 0.7)
            horizontalAlignment: Text.AlignRight
            text: value; color: valueColor; font.pixelSize: root.fontSmall; font.family: root.mono; elide: Text.ElideLeft
        }
    }

    // ---- stock page (original Stock Card layout) ------------------------------------
    Component {
        id: stockPage
        Column {
            id: col
            spacing: Math.max(2, root.u * 0.015)
            readonly property var s: root.stock
            readonly property bool ok: !!(s && s.ok && s.price !== undefined && s.price !== null)
            readonly property bool isUp: !!(s && s.up)
            Header { tag: root.page ? root.page.symbol : ""; title: col.s && col.s.name ? col.s.name : "" }
            Text {
                visible: !col.ok; width: parent.width; wrapMode: Text.WordWrap
                text: col.s && col.s.error ? col.s.error : root.statusMessage || i18n("Loading…")
                color: root.mutedColor; font.pixelSize: root.fontMid
            }
            BigNumber { visible: col.ok; text: col.ok ? root.money(col.s.price) : "" }
            Text {
                visible: col.ok
                text: (col.isUp ? "▲ " : "▼ ") + (col.ok ? root.signed(col.s.change) + "   " + root.signed(col.s.changePct, "%") : "")
                color: col.isUp ? root.upColor : root.downColor
                font.pixelSize: root.fontChg; font.bold: true; font.family: root.mono
            }
            Grid {
                visible: col.ok
                width: parent.width; columns: 2
                columnSpacing: Math.max(6, root.u * 0.04); rowSpacing: Math.max(1, root.u * 0.008)
                Repeater {
                    model: col.ok ? [
                        { l: "Prev", v: root.money(col.s.previousClose) },
                        { l: "Open", v: col.s.open ? root.money(col.s.open) : "—" },
                        { l: "Hi/Lo", v: col.s.high ? root.money(col.s.high) + "/" + root.money(col.s.low) : "—" },
                        { l: "Vol", v: col.s.volumeAlt || "—" }
                    ] : []
                    Row {
                        width: (col.width - Math.max(6, root.u * 0.04)) / 2
                        spacing: 3
                        Text { text: modelData.l; color: root.mutedColor; font.pixelSize: root.fontTiny; font.family: root.sans }
                        Text { text: modelData.v; color: root.textColor; font.pixelSize: root.fontSmall; font.family: root.mono; elide: Text.ElideRight }
                    }
                }
            }
            Canvas {
                id: spark
                width: parent.width
                height: Math.max(14, root.u * 0.16)
                visible: !!(col.s && col.s.history && col.s.history.length > 1)
                onPaint: {
                    var pts = (col.s && col.s.history) ? col.s.history : [];
                    var h = [];
                    for (var i = 0; i < pts.length; i++) h.push({ d: pts[i].date, v: pts[i].close });
                    root.drawSeries(spark, h, [], null);
                }
                Connections { target: root; function onDataVersionChanged() { spark.requestPaint(); } }
                Component.onCompleted: requestPaint()
            }
            Canvas {
                id: vol
                width: parent.width
                height: Math.max(8, root.u * 0.08)
                visible: spark.visible
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    var pts = (col.s && col.s.history) ? col.s.history : [];
                    var maxVol = 0;
                    for (var i = 0; i < pts.length; i++) maxVol = Math.max(maxVol, Number(pts[i].volume || 0));
                    if (maxVol <= 0 || pts.length < 2) return;
                    var slot = width / pts.length, barW = Math.max(1, slot * 0.62);
                    for (var j = 0; j < pts.length; j++) {
                        var barH = (Number(pts[j].volume || 0) / maxVol) * (height - 1);
                        var upDay = j === 0 || Number(pts[j].close) >= Number(pts[j - 1].close);
                        ctx.fillStyle = upDay ? "rgba(61, 220, 132, 0.58)" : "rgba(255, 82, 82, 0.58)";
                        ctx.fillRect(j * slot + (slot - barW) / 2, height - barH, barW, barH);
                    }
                }
                Connections { target: root; function onDataVersionChanged() { vol.requestPaint(); } }
                Component.onCompleted: requestPaint()
            }
            Text {
                width: parent.width
                visible: !!(col.s && col.s.news && col.s.news.title)
                text: col.s && col.s.news ? col.s.news.title : ""
                color: newsArea.containsMouse ? "#8AB4F8" : root.textColor
                font.pixelSize: root.fontTiny; font.family: root.sans
                elide: Text.ElideRight; maximumLineCount: 1; wrapMode: Text.NoWrap
                MouseArea {
                    id: newsArea
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: if (col.s && col.s.news && col.s.news.url) Qt.openUrlExternally(col.s.news.url)
                }
            }
        }
    }

    // ---- checking / savings ---------------------------------------------------------
    Component {
        id: cashPage
        Column {
            id: cc
            spacing: Math.max(1, root.u * 0.01)
            readonly property var a: root.account || ({})
            readonly property var low: a && a.forecastLow ? a.forecastLow : null
            readonly property bool chUp: !!(a && a.change && Number(a.change.amount) >= 0)
            Header { tag: root.badgeFor(cc.a); tagColor: root.accentColor; title: root.accountTitle(cc.a) }
            BigNumber { text: root.dollars(cc.a.balance) }
            Text {
                width: parent.width; elide: Text.ElideRight
                text: (cc.a.change ? (cc.chUp ? "▲ " : "▼ ") + root.signedDollars(cc.a.change.amount) + "  " + cc.a.change.days + "d" : "")
                color: cc.chUp ? root.upColor : root.downColor
                font.pixelSize: root.fontChg; font.bold: true; font.family: root.mono
            }
            Stat { visible: cc.a.available !== undefined; label: i18n("Available"); value: root.dollars(cc.a.available) }
            Canvas {
                id: cashChart
                width: parent.width
                height: Math.max(24, root.u * 0.2)
                onPaint: root.drawSeries(cashChart, cc.a.history, cc.a.forecast, cc.low)
                Connections { target: root; function onDataVersionChanged() { cashChart.requestPaint(); } }
                Component.onCompleted: requestPaint()
            }
            Stat {
                visible: !!cc.low
                label: i18n("7d low %1", cc.low ? root.shortDate(cc.low.d) : "")
                value: cc.low ? root.dollars(cc.low.v) : ""
                valueColor: cc.low && Number(cc.low.v) < 0 ? root.downColor : root.warnColor
            }
            Stat {
                visible: cc.a.forecastLowBillsOnly !== undefined && cc.a.discretionaryPerDay > 0
                label: i18n("Bills only")
                value: root.dollars(cc.a.forecastLowBillsOnly)
                valueColor: root.mutedColor
            }
            Repeater {
                model: cc.a.upcoming ? cc.a.upcoming.slice(0, 2) : []
                Stat {
                    label: root.shortDate(modelData.d).split(" ")[1] + " " + modelData.label
                    value: root.signedDollars(modelData.amount)
                    valueColor: Number(modelData.amount) >= 0 ? root.upColor : root.textColor
                }
            }
        }
    }

    // ---- retirement (401k / IRA / brokerage) ---------------------------------------------
    Component {
        id: retirementPage
        Column {
            id: rc
            spacing: Math.max(2, root.u * 0.014)
            readonly property var a: root.account || ({})
            readonly property bool chUp: !!(a && a.change && Number(a.change.amount) >= 0)
            Header { tag: root.badgeFor(rc.a); tagColor: root.accentColor; title: root.accountTitle(rc.a) }
            BigNumber { text: root.dollars(rc.a.balance) }
            Text {
                width: parent.width; elide: Text.ElideRight
                visible: !!rc.a.change
                text: rc.a.change ? (rc.chUp ? "▲ " : "▼ ") + root.signedDollars(rc.a.change.amount)
                      + (rc.a.change.pct !== null && rc.a.change.pct !== undefined
                         ? " " + (rc.a.change.pct >= 0 ? "+" : "−") + Math.abs(rc.a.change.pct).toFixed(1) + "%" : "")
                      + " " + rc.a.change.days + "d" : ""
                color: rc.chUp ? root.upColor : root.downColor
                font.pixelSize: root.fontChg; font.bold: true; font.family: root.mono
            }
            Canvas {
                id: retChart
                width: parent.width
                height: Math.max(24, root.u * 0.32)
                onPaint: root.drawSeries(retChart, rc.a.history, [], null)
                Connections { target: root; function onDataVersionChanged() { retChart.requestPaint(); } }
                Component.onCompleted: requestPaint()
            }
            Stat {
                label: i18n("YTD contributions")
                value: rc.a.ytdContributions === null || rc.a.ytdContributions === undefined ? "—" : root.dollars(rc.a.ytdContributions, 0)
            }
            Repeater {
                model: rc.a.extra || []
                Stat { label: modelData.label; value: root.dollars(modelData.value, 0) }
            }
            Text {
                visible: !!rc.a.estimated
                width: parent.width; elide: Text.ElideRight
                text: i18n("Trend estimated from index proxies")
                color: root.mutedColor; font.pixelSize: Math.max(7, root.fontTiny - 1); font.italic: true; font.family: root.sans
            }
        }
    }

    // ---- HSA ------------------------------------------------------------------------------
    Component {
        id: hsaPage
        Column {
            id: hc
            spacing: Math.max(2, root.u * 0.014)
            readonly property var a: root.account || ({})
            readonly property bool chUp: !!(a && a.change && Number(a.change.amount) >= 0)
            readonly property real limit: a && a.contributionLimit ? Number(a.contributionLimit) : 0
            readonly property real ytd: a && a.ytdContributions ? Number(a.ytdContributions) : 0
            Header { tag: "HSA"; tagColor: root.accentColor; title: root.accountTitle(hc.a) }
            BigNumber { text: root.dollars(hc.a.balance) }
            Text {
                width: parent.width; elide: Text.ElideRight
                visible: !!hc.a.change
                text: hc.a.change ? (hc.chUp ? "▲ " : "▼ ") + root.signedDollars(hc.a.change.amount) + "  " + hc.a.change.days + "d" : ""
                color: hc.chUp ? root.upColor : root.downColor
                font.pixelSize: root.fontChg; font.bold: true; font.family: root.mono
            }
            Canvas {
                id: hsaChart
                width: parent.width
                height: Math.max(20, root.u * 0.22)
                onPaint: root.drawSeries(hsaChart, hc.a.history, [], null)
                Connections { target: root; function onDataVersionChanged() { hsaChart.requestPaint(); } }
                Component.onCompleted: requestPaint()
            }
            Stat {
                label: i18n("YTD contrib")
                value: root.dollars(hc.a.ytdContributions, 0) + (hc.limit > 0 ? " / " + root.dollars(hc.limit, 0) : "")
            }
            Rectangle {
                visible: hc.limit > 0
                width: parent.width; height: Math.max(3, root.u * 0.022); radius: height / 2
                color: Qt.rgba(1, 1, 1, 0.15)
                Rectangle {
                    width: parent.width * Math.min(1, hc.ytd / Math.max(1, hc.limit)); height: parent.height; radius: parent.radius
                    color: root.accentColor
                }
            }
            Stat {
                visible: !!hc.a.medicalSpend
                label: i18n("Medical %1d", hc.a.medicalSpend ? hc.a.medicalSpend.days : 90)
                value: hc.a.medicalSpend ? root.dollars(hc.a.medicalSpend.amount) : ""
            }
            Repeater {
                model: hc.a.extra || []
                Stat { label: modelData.label; value: root.dollars(modelData.value, 0) }
            }
        }
    }

    // ---- account not found -------------------------------------------------------------------
    Component {
        id: missingPage
        Column {
            spacing: 4
            Header { tag: "ACCT"; tagColor: root.accentColor; title: root.page ? root.page.id : "" }
            Text {
                width: parent.width; wrapMode: Text.WordWrap
                color: root.mutedColor; font.pixelSize: root.fontSmall; font.family: root.sans
                text: root.accountsDoc && root.accountsDoc.error
                      ? root.accountsDoc.error + "\n" + root.accountsPath()
                      : (root.accountsDoc ? i18n("No account with id “%1” in the accounts file.", root.page ? root.page.id : "")
                                          : i18n("Loading…"))
            }
        }
    }
}
