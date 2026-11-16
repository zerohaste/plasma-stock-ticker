import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore

Item {
    id: root

    Plasmoid.preferredRepresentation: Plasmoid.fullRepresentation
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    readonly property bool inPanel: plasmoid.formFactor === PlasmaCore.Types.Horizontal
                                    || plasmoid.formFactor === PlasmaCore.Types.Vertical
                                    || plasmoid.location === PlasmaCore.Types.TopEdge
                                    || plasmoid.location === PlasmaCore.Types.BottomEdge
                                    || plasmoid.location === PlasmaCore.Types.LeftEdge
                                    || plasmoid.location === PlasmaCore.Types.RightEdge

    Layout.fillWidth: inPanel
    Layout.fillHeight: inPanel
    Layout.minimumWidth: inPanel ? 0 : 400
    Layout.minimumHeight: inPanel ? 24 : 32
    Layout.preferredWidth: inPanel ? 2560 : 1200
    Layout.preferredHeight: inPanel ? 36 : 40
    Layout.maximumWidth: inPanel ? 10000 : 10000
    Layout.maximumHeight: inPanel ? 4096 : 80

    readonly property color stripColor: Qt.rgba(0, 0, 0, 0.78)
    readonly property color textColor: "#F2F2F2"
    readonly property color upColor: "#3DDC84"
    readonly property color downColor: "#FF5252"
    readonly property color mutedColor: "#B0B0B0"
    readonly property int itemGap: 36

    property var quotes: []
    property string statusMessage: i18n("Loading quotes…")
    property string lastError: ""

    function symbolList() {
        var raw = String(plasmoid.configuration.symbols || "");
        var parts = raw.split(/[\s,;]+/);
        var out = [];
        var seen = {};
        for (var i = 0; i < parts.length; i++) {
            var s = parts[i].trim();
            if (!s) continue;
            s = s.replace(/[^A-Za-z0-9.^_=-]/g, "");
            if (!s) continue;
            var key = s.toUpperCase();
            if (seen[key]) continue;
            seen[key] = true;
            out.push(s.toUpperCase());
        }
        return out;
    }

    function toCnbc(sym) {
        var s = String(sym).toUpperCase();
        if (s === "^VIX" || s === "VIX" || s === ".VIX") return ".VIX";
        if (s === "BTC-USD" || s === "BTCUSD" || s === "BTC" || s === "BTC.CM=") return "BTC.CM=";
        if (s === "ETH-USD" || s === "ETHUSD" || s === "ETH" || s === "ETH.CM=") return "ETH.CM=";
        if (s === "^GSPC" || s === "^SPX" || s === "SPX" || s === ".SPX") return ".SPX";
        if (s === "^DJI" || s === "DJI" || s === ".DJI") return ".DJI";
        if (s === "^IXIC" || s === "IXIC" || s === "COMP" || s === ".IXIC") return ".IXIC";
        if (s === "^RUT" || s === ".RUT") return ".RUT";
        return s;
    }

    function displaySymbol(sym) {
        var s = String(sym).toUpperCase();
        if (s === ".VIX") return "^VIX";
        if (s === "BTC.CM=") return "BTC-USD";
        if (s === "ETH.CM=") return "ETH-USD";
        if (s === ".SPX") return "^GSPC";
        if (s === ".DJI") return "^DJI";
        if (s === ".IXIC") return "^IXIC";
        if (s === ".RUT") return "^RUT";
        return s;
    }

    function parseChangePct(text) {
        if (text === undefined || text === null) return 0;
        var n = parseFloat(String(text).replace(/[%+,]/g, ""));
        return isNaN(n) ? 0 : n;
    }

    function applyQuotes(items) {
        quotes = items;
        if (!items || items.length === 0) {
            statusMessage = lastError || i18n("No quotes yet");
        } else {
            statusMessage = "";
        }
        Qt.callLater(restartScroll);
    }

    function restartScroll() {
        scrollAnim.stop();
        scroller.x = 0;
        if (copyA.width > 0 && copyA.width > viewport.width && quotes.length > 0) {
            scrollAnim.to = -copyA.width;
            scrollAnim.duration = Math.max(12000, Math.round(copyA.width * 18));
            scrollAnim.start();
        }
    }

    function fetchQuotes() {
        var symbols = symbolList();
        if (symbols.length === 0) {
            lastError = "";
            applyQuotes([]);
            statusMessage = i18n("Add symbols in Configure Stock Ticker…");
            return;
        }

        var mapped = [];
        var reverse = {};
        for (var i = 0; i < symbols.length; i++) {
            var cnbc = toCnbc(symbols[i]);
            if (!cnbc) continue;
            mapped.push(cnbc);
            if (!reverse[cnbc]) reverse[cnbc] = symbols[i];
        }

        var url = "https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol?symbols="
                  + mapped.join("|")
                  + "&requestMethod=itv&noform=1&partnerId=2&output=json";
        var cmd = "curl -sS --max-time 20 -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' -H 'Accept: application/json' '" + url + "'";
        fetcher.exec(cmd, reverse, symbols);
    }

    PlasmaCore.DataSource {
        id: fetcher
        engine: "executable"
        connectedSources: []
        property var pendingMap: ({})
        property var pendingSymbols: []

        onNewData: {
            var stdout = data["stdout"] || "";
            var stderr = data["stderr"] || "";
            var code = data["exit code"];
            disconnectSource(sourceName);

            if (code !== 0 || !stdout) {
                lastError = i18n("Quote update failed — will retry");
                if (quotes.length === 0) applyQuotes([]);
                else statusMessage = "";
                console.log("stockticker curl failed:", code, stderr);
                return;
            }
            try {
                var parsed = JSON.parse(stdout);
                var raw = parsed && parsed.FormattedQuoteResult && parsed.FormattedQuoteResult.FormattedQuote;
                if (!raw) throw new Error("missing FormattedQuote");
                if (!Array.isArray(raw)) raw = [raw];

                var byCnbc = {};
                for (var i = 0; i < raw.length; i++) {
                    var q = raw[i];
                    if (q && q.symbol) byCnbc[q.symbol] = q;
                }

                var items = [];
                var symbols = pendingSymbols;
                for (var j = 0; j < symbols.length; j++) {
                    var orig = symbols[j];
                    var key = toCnbc(orig);
                    var q2 = byCnbc[key];
                    if (!q2 || (q2.code !== undefined && q2.code !== 0 && q2.code !== "0")) {
                        items.push({
                            symbol: orig,
                            priceText: "—",
                            changeText: "",
                            up: true,
                            valid: false
                        });
                        continue;
                    }
                    var pct = parseChangePct(q2.change_pct);
                    var up = pct > 0 || String(q2.changetype || "").toUpperCase() === "UP";
                    if (pct === 0 && String(q2.changetype || "").toUpperCase() === "DOWN") up = false;
                    var pctText = q2.change_pct ? String(q2.change_pct).replace("+", "") : "";
                    items.push({
                        symbol: orig,
                        priceText: String(q2.last || "—"),
                        changeText: pctText,
                        up: up,
                        valid: true
                    });
                }
                lastError = "";
                applyQuotes(items);
            } catch (e) {
                lastError = i18n("Quote update failed — will retry");
                if (quotes.length === 0) applyQuotes([]);
                console.log("stockticker parse failed:", e);
            }
        }

        function exec(cmd, reverse, symbols) {
            pendingMap = reverse || {};
            pendingSymbols = symbols || [];
            connectSource(cmd);
        }
    }

    Timer {
        id: refreshTimer
        interval: Math.max(60, plasmoid.configuration.refreshIntervalSeconds || 300) * 1000
        repeat: true
        running: true
        onTriggered: fetchQuotes()
    }

    Connections {
        target: plasmoid.configuration
        function onSymbolsChanged() { fetchQuotes(); }
        function onRefreshIntervalSecondsChanged() {
            refreshTimer.interval = Math.max(60, plasmoid.configuration.refreshIntervalSeconds || 300) * 1000;
            fetchQuotes();
        }
    }

    Component.onCompleted: fetchQuotes()

    Rectangle {
        anchors.fill: parent
        color: root.stripColor
        radius: root.inPanel ? 0 : 4
        border.color: Qt.rgba(1, 1, 1, root.inPanel ? 0.08 : 0.12)
        border.width: root.inPanel ? 0 : 1

        Item {
            id: viewport
            anchors.fill: parent
            anchors.leftMargin: root.inPanel ? 8 : 10
            anchors.rightMargin: root.inPanel ? 8 : 10
            clip: true

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: quotes.length === 0
                text: statusMessage
                color: root.mutedColor
                font.pixelSize: Math.max(12, Math.round(parent.height * 0.45))
                font.family: "Noto Sans, DejaVu Sans, sans-serif"
            }

            Row {
                id: scroller
                height: parent.height
                spacing: 0
                visible: quotes.length > 0

                Row {
                    id: copyA
                    height: parent.height
                    spacing: 0
                    Repeater {
                        model: quotes
                        delegate: quoteDelegate
                    }
                }
                Row {
                    id: copyB
                    height: parent.height
                    spacing: 0
                    Repeater {
                        model: quotes
                        delegate: quoteDelegate
                    }
                }
            }

            NumberAnimation {
                id: scrollAnim
                target: scroller
                property: "x"
                from: 0
                loops: Animation.Infinite
                easing.type: Easing.Linear
            }

            Timer {
                interval: 400
                running: quotes.length > 0
                repeat: true
                onTriggered: {
                    if (!scrollAnim.running && copyA.width > viewport.width) restartScroll();
                }
            }
        }
    }

    Component {
        id: quoteDelegate
        Item {
            width: row.implicitWidth + root.itemGap
            height: scroller.height
            Row {
                id: row
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                Text {
                    text: modelData.symbol
                    color: root.textColor
                    font.pixelSize: Math.max(12, Math.round(root.height * 0.42))
                    font.bold: true
                    font.family: "Noto Sans, DejaVu Sans, sans-serif"
                }
                Text {
                    text: modelData.priceText
                    color: root.textColor
                    font.pixelSize: Math.max(12, Math.round(root.height * 0.42))
                    font.family: "Noto Sans Mono, DejaVu Sans Mono, monospace"
                }
                Text {
                    visible: modelData.valid && modelData.changeText
                    text: (modelData.up ? "▲ " : "▼ ") + modelData.changeText
                    color: modelData.up ? root.upColor : root.downColor
                    font.pixelSize: Math.max(12, Math.round(root.height * 0.40))
                    font.bold: true
                    font.family: "Noto Sans, DejaVu Sans, sans-serif"
                }
            }
        }
    }

    Connections {
        target: copyA
        function onWidthChanged() { Qt.callLater(restartScroll); }
    }
}
