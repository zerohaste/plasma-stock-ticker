import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

ColumnLayout {
    property alias cfg_items: itemsArea.text
    property alias cfg_cycleSeconds: cycleSpin.value
    property alias cfg_pauseOnHover: pauseBox.checked
    property alias cfg_accountsFile: accountsField.text
    property alias cfg_refreshMarketSeconds: marketSpin.value
    property alias cfg_refreshOffhoursSeconds: offSpin.value

    anchors.fill: parent
    spacing: 8

    Label { text: i18n("Pages"); font.bold: true }
    Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: i18n("One page per line. A stock symbol (AAPL), a symbol with its own news search (TSLA | Tesla stock), or an account from your accounts file (@checking-1234). Lines starting with # are ignored.")
    }
    ScrollView {
        Layout.fillWidth: true
        Layout.preferredHeight: 130
        TextArea {
            id: itemsArea
            font.family: "monospace"
            placeholderText: "AAPL\nMSFT | Microsoft stock\n@checking-1234"
        }
    }

    RowLayout {
        Label { text: i18n("Seconds per page (0 = off)") }
        SpinBox { id: cycleSpin; from: 0; to: 600; stepSize: 5; editable: true }
    }
    CheckBox { id: pauseBox; text: i18n("Pause while the pointer is over the card") }

    Label { text: i18n("Accounts file"); font.bold: true }
    Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: i18n("A local JSON file you control (see the README for the schema). The widget only reads it; it never stores or asks for bank credentials.")
    }
    TextField { id: accountsField; Layout.fillWidth: true; placeholderText: "~/.local/share/controllimit-hud/accounts.json" }

    RowLayout {
        Label { text: i18n("Refresh in market hours (s)") }
        SpinBox { id: marketSpin; from: 15; to: 3600; stepSize: 15; editable: true }
    }
    RowLayout {
        Label { text: i18n("Refresh after hours (s)") }
        SpinBox { id: offSpin; from: 60; to: 3600; stepSize: 30; editable: true }
    }
    Item { Layout.fillHeight: true }
}
