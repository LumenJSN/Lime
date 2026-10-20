import Foundation

/// WordprocessingML writer with real heading styles, numbered and bulleted
/// lists, tables, hyperlinks and inline images.
enum DOCXWriter {
    static func write(_ document: SemanticDocument, title: String, to destination: URL, workspace: URL) async throws {
        var body = ""
        var rels: [String] = []
        var media: [String: Data] = [:]
        var imageCount = 0, linkCount = 0

        // Direct formatting mirrors the styles for readers that ignore styles.xml.
        let baseFont = "<w:rFonts w:ascii=\"Helvetica Neue\" w:hAnsi=\"Helvetica Neue\" w:eastAsia=\"Apple SD Gothic Neo\" w:cs=\"Helvetica Neue\"/>"
        var baseBold = false, baseItalic = false, baseSize = 22
        func runs(_ inlines: [SemanticDocument.Inline]) -> String {
            var xml = ""
            for inline in inlines {
                switch inline {
                case .image(let image):
                    imageCount += 1
                    let id = "rIdImg\(imageCount)", name = "image\(imageCount).\(image.ext)"
                    media["word/media/" + name] = image.data
                    rels.append("<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>")
                    let maxWidth = 5_486_400.0
                    var cx = max(1, Double(image.width)) * 12_700, cy = max(1, Double(image.height)) * 12_700
                    if cx > maxWidth { cy *= maxWidth / cx; cx = maxWidth }
                    xml += drawing(id: id, index: imageCount, cx: Int(cx), cy: Int(cy))
                case .run(let run):
                    // CT_RPr order: rFonts, b, i, strike, sz, szCs, u.
                    var props = run.code ? "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/>" : baseFont
                    if run.bold || baseBold { props += "<w:b/>" }
                    if run.italic || baseItalic { props += "<w:i/>" }
                    if run.strike { props += "<w:strike/>" }
                    props += "<w:sz w:val=\"\(baseSize)\"/><w:szCs w:val=\"\(baseSize)\"/>"
                    if run.underline { props += "<w:u w:val=\"single\"/>" }
                    let pieces = run.text.components(separatedBy: "\n")
                    var text = ""
                    for (i, piece) in pieces.enumerated() {
                        if i > 0 { text += "<w:br/>" }
                        if !piece.isEmpty { text += "<w:t xml:space=\"preserve\">\(XMLText.escape(piece.replacingOccurrences(of: "\t", with: " ")))</w:t>" }
                    }
                    if let link = run.link, let url = URL(string: link), url.scheme != nil {
                        linkCount += 1
                        let id = "rIdLink\(linkCount)"
                        rels.append("<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(XMLText.escape(link))\" TargetMode=\"External\"/>")
                        xml += "<w:hyperlink r:id=\"\(id)\"><w:r><w:rPr><w:rStyle w:val=\"Hyperlink\"/>\(props)</w:rPr>\(text)</w:r></w:hyperlink>"
                    } else {
                        xml += "<w:r><w:rPr>\(props)</w:rPr>\(text)</w:r>"
                    }
                }
            }
            return xml
        }

        for block in document.blocks {
            try Task.checkCancellation()
            baseBold = false; baseItalic = false; baseSize = 22
            if case .heading(let level, _) = block {
                baseBold = true; baseItalic = level >= 4; baseSize = [0, 40, 32, 26, 22][min(4, level)]
            }
            switch block {
            case .heading(let level, let inlines):
                body += "<w:p><w:pPr><w:pStyle w:val=\"Heading\(min(4, level))\"/></w:pPr>\(runs(inlines))</w:p>"
            case .paragraph(let inlines):
                body += "<w:p>\(runs(inlines))</w:p>"
            case .listItem(let ordered, let level, let inlines):
                body += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(min(8, level))\"/><w:numId w:val=\"\(ordered ? 2 : 1)\"/></w:numPr></w:pPr>\(runs(inlines))</w:p>"
            case .rule:
                body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BFBFBF\"/></w:pBdr></w:pPr></w:p>"
            case .table(let rows):
                let columns = rows.map(\.count).max() ?? 1
                guard columns <= 63 else { throw LimeError("A table in the document is too big or has broken column widths.") }
                let width = 9360 / max(1, columns)
                body += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblLook w:val=\"04A0\" w:firstRow=\"1\"/></w:tblPr><w:tblGrid>"
                body += String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
                for (r, row) in rows.enumerated() {
                    body += "<w:tr>"
                    for c in 0..<columns {
                        let cell = c < row.count ? row[c] : []
                        let content = runs(r == 0 && rows.count > 1 ? cell.map(bold) : cell)
                        body += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr><w:p>\(content)</w:p></w:tc>"
                    }
                    body += "</w:tr>"
                }
                body += "</w:tbl><w:p/>"
            }
        }
        if body.isEmpty { body = "<w:p/>" }
        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""
        let page = DocumentRenderer.defaultPageSize
        let pageXML = "<w:sectPr><w:pgSz w:w=\"\(Int(page.width * 20))\" w:h=\"\(Int(page.height * 20))\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
        var files: [String: Data] = media
        files["word/document.xml"] = Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document \(ns)><w:body>\(body)\(pageXML)</w:body></w:document>".utf8)
        files["word/_rels/document.xml.rels"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        \(rels.joined(separator: "\n"))
        </Relationships>
        """.utf8)
        files["word/styles.xml"] = Data(styles.utf8)
        files["word/numbering.xml"] = Data(numbering.utf8)
        files["docProps/core.xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(XMLText.escape(title))</dc:title></cp:coreProperties>
        """.utf8)
        files["_rels/.rels"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        </Relationships>
        """.utf8)
        files["[Content_Types].xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Default Extension="jpeg" ContentType="image/jpeg"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        </Types>
        """.utf8)
        try await ZipPackage.write(files, to: destination, workspace: workspace)
    }

    private static func bold(_ inline: SemanticDocument.Inline) -> SemanticDocument.Inline {
        if case .run(var r) = inline { r.bold = true; return .run(r) }
        return inline
    }

    private static func drawing(id: String, index: Int, cx: Int, cy: Int) -> String {
        """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(index)" name="Picture \(index)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:nvPicPr><pic:cNvPr id="\(index)" name="Picture \(index)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:eastAsia="Apple SD Gothic Neo" w:cs="Helvetica Neue"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault>
    <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:i/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/></w:pPr></w:style>
    <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:color="BFBFBF"/><w:left w:val="single" w:sz="4" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:color="BFBFBF"/><w:right w:val="single" w:sz="4" w:color="BFBFBF"/><w:insideH w:val="single" w:sz="4" w:color="BFBFBF"/><w:insideV w:val="single" w:sz="4" w:color="BFBFBF"/></w:tblBorders><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
    </w:styles>
    """

    private static var numbering: String {
        func levels(_ ordered: Bool) -> String {
            (0..<9).map { l in
                let fmt = ordered ? (l % 3 == 0 ? "decimal" : l % 3 == 1 ? "lowerLetter" : "lowerRoman") : "bullet"
                let text = ordered ? "%\(l + 1)." : (l % 3 == 0 ? "•" : l % 3 == 1 ? "◦" : "▪")
                return "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + l * 360)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(false))</w:abstractNum>
        <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(true))</w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
    }
}
