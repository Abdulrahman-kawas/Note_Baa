import Foundation

/// A one-sheet Excel workbook (.xlsx) without any library: the few SpreadsheetML parts Excel, Numbers
/// and Google Sheets need, in a ZIP archive whose entries are stored uncompressed (allowed by the
/// format, and these sheets are small).
enum XLSXWriter {
    enum Cell {
        case number(Int)
        case text(String)
        /// Bold, for the column the row is about.
        case strong(String)
        /// Centered, for short values such as times.
        case centered(String)
    }

    struct Column {
        let header: String
        /// In characters, as Excel measures it.
        let width: Double
    }

    struct Sheet {
        var name: String
        /// Merged across the columns above the header row.
        var title: String
        var columns: [Column]
        var rows: [[Cell]]
        /// Columns run from the right, as Arabic readers expect.
        var rightToLeft = false
    }

    static func data(for sheet: Sheet) -> Data {
        var archive = ZipArchive()
        archive.add("[Content_Types].xml", contentTypes)
        archive.add("_rels/.rels", rootRelationships)
        archive.add("xl/workbook.xml", workbook(for: sheet))
        archive.add("xl/_rels/workbook.xml.rels", workbookRelationships)
        archive.add("xl/styles.xml", styles)
        archive.add("xl/worksheets/sheet1.xml", worksheet(for: sheet))
        return archive.finish()
    }

    // MARK: - Parts

    private static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private static let contentTypes = header + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
    </Types>
    """

    private static let rootRelationships = header + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="\(relationshipNamespace)/officeDocument" Target="xl/workbook.xml"/>\
    </Relationships>
    """

    private static let workbookRelationships = header + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="\(relationshipNamespace)/worksheet" Target="worksheets/sheet1.xml"/>\
    <Relationship Id="rId2" Type="\(relationshipNamespace)/styles" Target="styles.xml"/>\
    </Relationships>
    """

    /// Cell formats, by index: 1 title, 2 header, 3 body (wrapped, top), 4 centered, 5 bold body.
    private static let styles = header + """
    <styleSheet xmlns="\(mainNamespace)">\
    <fonts count="3">\
    <font><sz val="12"/><name val="Calibri"/></font>\
    <font><b/><sz val="12"/><name val="Calibri"/></font>\
    <font><b/><sz val="15"/><name val="Calibri"/></font>\
    </fonts>\
    <fills count="3">\
    <fill><patternFill patternType="none"/></fill>\
    <fill><patternFill patternType="gray125"/></fill>\
    <fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/><bgColor indexed="64"/></patternFill></fill>\
    </fills>\
    <borders count="2">\
    <border><left/><right/><top/><bottom/><diagonal/></border>\
    <border><left/><right/><top/><bottom style="thin"><color rgb="FFBFBFBF"/></bottom><diagonal/></border>\
    </borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="6">\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
    <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>\
    <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top"/></xf>\
    <xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>\
    </cellXfs>\
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
    </styleSheet>
    """

    private static func workbook(for sheet: Sheet) -> String {
        let name = sheetName(sheet.name)
        let lastRow = max(sheet.rows.count + 2, 2)
        let range = "'\(name.replacingOccurrences(of: "'", with: "''"))'!$A$2:$\(column(sheet.columns.count))$\(lastRow)"
        return header + """
        <workbook xmlns="\(mainNamespace)" xmlns:r="\(relationshipNamespace)">\
        <sheets><sheet name="\(escape(name))" sheetId="1" r:id="rId1"/></sheets>\
        <definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">\(escape(range))</definedName></definedNames>\
        </workbook>
        """
    }

    private static func worksheet(for sheet: Sheet) -> String {
        let lastColumn = column(sheet.columns.count)
        var xml = header + #"<worksheet xmlns="\#(mainNamespace)">"#
        // The title and header rows stay in view while scrolling.
        xml += #"<sheetViews><sheetView workbookViewId="0"\#(sheet.rightToLeft ? #" rightToLeft="1""# : "")>"#
        xml += #"<pane ySplit="2" topLeftCell="A3" activePane="bottomLeft" state="frozen"/>"#
        xml += #"<selection pane="bottomLeft" activeCell="A3" sqref="A3"/></sheetView></sheetViews>"#
        xml += "<cols>"
        for (index, item) in sheet.columns.enumerated() {
            xml += #"<col min="\#(index + 1)" max="\#(index + 1)" width="\#(item.width)" customWidth="1"/>"#
        }
        xml += "</cols><sheetData>"
        xml += #"<row r="1" ht="26" customHeight="1">"# + textCell("A1", sheet.title, style: 1) + "</row>"
        xml += #"<row r="2">"#
        for (index, item) in sheet.columns.enumerated() {
            xml += textCell("\(column(index + 1))2", item.header, style: 2)
        }
        xml += "</row>"
        for (rowIndex, row) in sheet.rows.enumerated() {
            let number = rowIndex + 3
            xml += #"<row r="\#(number)">"#
            for (index, cell) in row.prefix(sheet.columns.count).enumerated() {
                let reference = "\(column(index + 1))\(number)"
                switch cell {
                case .number(let value): xml += #"<c r="\#(reference)" s="4"><v>\#(value)</v></c>"#
                case .text(let value): xml += textCell(reference, value, style: 3)
                case .strong(let value): xml += textCell(reference, value, style: 5)
                case .centered(let value): xml += textCell(reference, value, style: 4)
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData>"
        xml += #"<autoFilter ref="A2:\#(lastColumn)\#(max(sheet.rows.count + 2, 2))"/>"#
        xml += #"<mergeCells count="1"><mergeCell ref="A1:\#(lastColumn)1"/></mergeCells>"#
        xml += #"<pageMargins left="0.5" right="0.5" top="0.6" bottom="0.6" header="0.3" footer="0.3"/>"#
        return xml + "</worksheet>"
    }

    // MARK: - Helpers

    private static func textCell(_ reference: String, _ text: String, style: Int) -> String {
        #"<c r="\#(reference)" t="inlineStr" s="\#(style)"><is><t xml:space="preserve">\#(escape(text))</t></is></c>"#
    }

    /// 1 → A … 26 → Z, 27 → AA.
    private static func column(_ number: Int) -> String {
        var number = max(number, 1)
        var name = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            number = (number - 1) / 26
        }
        return name
    }

    /// Excel refuses sheet names over 31 characters or with any of : \ / ? * [ ].
    private static func sheetName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: ":\\/?*[]")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Sheet1" : String(cleaned.prefix(31))
    }

    /// XML escaping, dropping the control characters XML 1.0 can't carry.
    private static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

/// A ZIP archive with stored (uncompressed) entries.
private struct ZipArchive {
    private var body = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    /// 1 January 1980, the DOS epoch: the date isn't needed and a fixed one keeps files identical.
    private let dosTime: UInt16 = 0
    private let dosDate: UInt16 = (1 << 5) | 1

    mutating func add(_ path: String, _ text: String) {
        let content = Data(text.utf8)
        let name = Data(path.utf8)
        let crc = Self.crc32(content)
        let offset = UInt32(body.count)

        body.append32(0x0403_4B50)
        body.append16(20)  // version needed
        body.append16(0)   // flags
        body.append16(0)   // stored
        body.append16(dosTime)
        body.append16(dosDate)
        body.append32(crc)
        body.append32(UInt32(content.count))
        body.append32(UInt32(content.count))
        body.append16(UInt16(name.count))
        body.append16(0)   // extra field
        body.append(name)
        body.append(content)

        directory.append32(0x0201_4B50)
        directory.append16(20)  // made by
        directory.append16(20)  // version needed
        directory.append16(0)
        directory.append16(0)
        directory.append16(dosTime)
        directory.append16(dosDate)
        directory.append32(crc)
        directory.append32(UInt32(content.count))
        directory.append32(UInt32(content.count))
        directory.append16(UInt16(name.count))
        directory.append16(0)   // extra field
        directory.append16(0)   // comment
        directory.append16(0)   // disk
        directory.append16(0)   // internal attributes
        directory.append32(0)   // external attributes
        directory.append32(offset)
        directory.append(name)
        count += 1
    }

    func finish() -> Data {
        var data = body
        data.append(directory)
        data.append32(0x0605_4B50)
        data.append16(0)
        data.append16(0)
        data.append16(count)
        data.append16(count)
        data.append32(UInt32(directory.count))
        data.append32(UInt32(body.count))
        data.append16(0)
        return data
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}
