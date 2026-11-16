import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

ColumnLayout {
    id: page
    property alias cfg_symbols: symbolsField.text
    property alias cfg_refreshIntervalSeconds: intervalSpin.value

    anchors.fill: parent
    spacing: 12

    Label {
        text: i18n("Symbols")
        font.bold: true
    }
    Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: i18n("Comma- or space-separated ticker symbols. Use ordinary symbols such as NVDA, plus ^VIX and BTC-USD.")
    }
    TextField {
        id: symbolsField
        Layout.fillWidth: true
        placeholderText: "AAPL, MSFT, NVDA"
    }

    Label {
        text: i18n("Refresh interval (seconds)")
        font.bold: true
    }
    SpinBox {
        id: intervalSpin
        from: 60
        to: 3600
        stepSize: 30
        editable: true
    }

    Item { Layout.fillHeight: true }
}
