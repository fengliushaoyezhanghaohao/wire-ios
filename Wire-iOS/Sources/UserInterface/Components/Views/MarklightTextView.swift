//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import UIKit
import Marklight

let MarklightTextViewDidChangeSelectionNotification = "MarklightTextViewDidChangeSelectionNotification"

public class MarklightTextView: NextResponderTextView {
    
    public let style: MarklightStyle
    fileprivate let marklightTextStorage: MarklightTextStorage
    
    fileprivate var nextListNumber = 1
    fileprivate var nextListBullet = "-"
    fileprivate var needsNewNumberListItem = false
    fileprivate var needsNewBulletListItem = false
    
    fileprivate let defaultAttributes: [String: Any] = [
        NSForegroundColorAttributeName: ColorScheme.default().color(withName: ColorSchemeColorTextForeground),
        NSFontAttributeName: FontSpec(.normal, .none).font!,
        NSParagraphStyleAttributeName: NSMutableParagraphStyle.default,
        NSKernAttributeName: 0.295
    ]

    public override var selectedTextRange: UITextRange? {
        didSet {
            NotificationCenter.default.post(name: Notification.Name(rawValue: MarklightTextViewDidChangeSelectionNotification), object: self)
            // invalidate list item prefixes
            nextListNumber = 1
            nextListBullet = "-"
        }
    }
    
    public override init(frame: CGRect, textContainer: NSTextContainer?) {
        
        style = MarklightTextView.defaultMarkdownStyle()
        marklightTextStorage = MarklightTextStorage(style: style)
        
        marklightTextStorage.defaultAttributes = defaultAttributes
        let marklightLayoutManager = NSLayoutManager()
        marklightTextStorage.addLayoutManager(marklightLayoutManager)
        
        let marklightTextContainer = NSTextContainer()
        marklightLayoutManager.addTextContainer(marklightTextContainer)
        
        super.init(frame: frame, textContainer: marklightTextContainer)
        
        NotificationCenter.default.addObserver(self, selector: #selector(textChangedHandler), name: NSNotification.Name.UITextViewTextDidChange, object: self)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    class func defaultMarkdownStyle() -> MarklightStyle {
        
        let defaultFont = FontSpec(.normal, .light).font!
        let colorScheme = ColorScheme.default()
        let style = MarklightStyle()
        
        style.syntaxAttributes = [NSForegroundColorAttributeName: colorScheme.accentColor]
        style.italicAttributes = [NSFontAttributeName: defaultFont.italicFont()]
        style.codeAttributes[NSForegroundColorAttributeName] = colorScheme.color(withName: ColorSchemeColorTextForeground)
        style.blockQuoteAttributes[NSForegroundColorAttributeName] = colorScheme.color(withName: ColorSchemeColorTextForeground)
        style.fontTextStyle = UIFontTextStyle.subheadline.rawValue
        style.hideSyntax = false
        
        return style
    }
}


// MARK: - Text Stripping

extension MarklightTextView {
    
    /// Returns the current text buffer sans empty markdown elements and
    /// leading/trailing whitespace within non empty markdown elements.
    ///
    public var preparedText: String {
        get {
            var text = self.text!
            var rangesToDelete = rangesOfEmptyMarkdownElements()
            rangesToDelete += rangesOfMarkdownWhitespace()
            rangesToDelete += rangesOfSyntaxForMarkdownEmoji()
            
            // discard nested ranges, sort by location descending
            rangesToDelete = flattenRanges(rangesToDelete).sorted {
                return $0.location >= $1.location
            }
            
            // strip empty markdown
            rangesToDelete.forEach {
                text.deleteCharactersIn(range: $0)
            }
            
            // strip empty list items
            let numberListPrefix = "(^\\d+)(?:[.][\\t ]*$)"
            let bulletListPrefix = "(^[*+-])([\\t ]*$)"
            let listPrefixPattern = "(\(numberListPrefix))|(\(bulletListPrefix))"
            let regex = try! NSRegularExpression(pattern: listPrefixPattern, options: [.anchorsMatchLines])
            let wholeRange = NSMakeRange(0, text.characters.count)
            text = regex.stringByReplacingMatches(in: text, options: [], range: wholeRange, withTemplate: "")
            
            return text
        }
    }
}

// MARK: - Markdown Insertion

extension MarklightTextView {
    
    public func insertSyntaxForMarkdownElement(type: MarkdownElementType) {
        
        guard let selection = selectedTextRange else { return }
        
        switch type {
        case .header(let size):
            
            let syntax: String
            switch size {
            case .h1: syntax = "# "
            case .h2: syntax = "## "
            case .h3: syntax = "### "
            }
            
            insertPrefixSyntax(syntax, forSelection: selection)
            
        case .numberList:   insertPrefixSyntax("\(nextListNumber). ", forSelection: selection)
        case .bulletList:   insertPrefixSyntax("\(nextListBullet) ", forSelection: selection)
        case .bold:         insertWrapSyntax("**", forSelection: selection)
        case .italic:       insertWrapSyntax("_", forSelection: selection)
        case .code:         insertWrapSyntax("`", forSelection: selection)
        default: return
        }
    }
    
    fileprivate func insertPrefixSyntax(_ syntax: String, forSelection selection: UITextRange) {
        
        // original start
        let start = selection.start
        // insert syntax at start of line
        let lineStart = lineStartForTextAtPosition(start)
        replace(textRange(from: lineStart, to: lineStart)!, withText: syntax)
        // preserve relative caret position
        let newPos = position(from: start, offset: syntax.characters.count)!
        selectedTextRange = textRange(from: newPos, to: newPos)
    }
    
    fileprivate func insertWrapSyntax(_ syntax: String, forSelection selection: UITextRange) {
        
        // original start
        let start = selection.start
        
        // wrap syntax around selection
        if !selection.isEmpty {
            let preRange = textRange(from: start, to: start)!
            replace(preRange, withText: syntax)
            
            // offset acounts for first insertion
            let end = position(from: selection.end, offset: syntax.characters.count)!
            let postRange = textRange(from: end, to: end)!
            replace(postRange, withText: syntax)
        }
        else {
            // insert syntax & move caret inside
            replace(selection, withText: syntax + syntax)
            let newPos = position(from: start, offset: syntax.characters.count)!
            selectedTextRange = textRange(from: newPos, to: newPos)
        }
    }
}

// MARK: - Markdown Deletion
    
extension MarklightTextView {
    
    public func deleteSyntaxForMarkdownElement(type: MarkdownElementType) {
        
        switch type {
        case .header(_), .numberList, .bulletList:
            removePrefixSyntaxForElement(type: type, forSelection: selectedRange)
        case .italic, .bold, .code:
            removeWrapSyntaxForElement(type: type, forSelection: selectedRange)
        default: return
        }
    }

    fileprivate func removePrefixSyntaxForElement(type: MarkdownElementType, forSelection selection: NSRange) {
        
        guard
            let range = rangeForMarkdownElement(type: type, enclosingSelection: selection),
            let preRange = range.preRange
            else { return }
        
        let lineRange = (text as NSString).lineRange(for: selection)
        text.deleteCharactersIn(range: preRange)
        
        // shift selection location to account for removal, but don't exceed line start
        let location = max(lineRange.location, selection.location - preRange.length)
        
        // how much of selection was part of syntax
        let length = NSIntersectionRange(preRange, selection).length
        
        // preserve relative selection
        selectedRange = NSMakeRange(location, selection.length - length)
    }
    
    fileprivate func removeWrapSyntaxForElement(type: MarkdownElementType, forSelection selection: NSRange) {
        
        guard
            let range = rangeForMarkdownElement(type: type, enclosingSelection: selection),
            let preRange = range.preRange,
            let postRange = range.postRange
            else { return }
        
        // remove postRange first so preRange is still valid
        text.deleteCharactersIn(range: postRange)
        text.deleteCharactersIn(range: preRange)
        
        // reposition caret:
        // if non zero selection or caret pos was within postRange
        if selection.length > 0 || NSEqualRanges(postRange, NSUnionRange(selection, postRange)) {
            // move caret to end of token
            selectedRange = NSMakeRange(postRange.location - preRange.length, 0)
        }
        else if NSEqualRanges(preRange, NSUnionRange(selection, preRange)) {
            // caret was within preRange, move caret to start of token
            selectedRange = NSMakeRange(preRange.location, 0)
        }
        else {
            // caret pos was between syntax, preserve relative position
            selectedRange = NSMakeRange(selection.location - preRange.length, 0)
        }
    }
}

// MARK: - Range calculations

extension MarklightTextView {
    
    /// Returns all ranges of all markdown elements.
    ///
    fileprivate func allMarkdownRanges() -> [MarkdownRange] {
        
        let types: [MarkdownElementType] = [
            .header(.h1), .header(.h2), .header(.h3), .bold,
            .italic, .numberList, .bulletList, .code, .quote
        ]
        
        var ranges = [MarkdownRange]()
        let groupStyler = marklightTextStorage.groupStyler
        types.forEach { ranges += groupStyler.rangesForElementType($0) }
        return ranges
    }
    
    fileprivate func lineStartForTextAtPosition(_ pos: UITextPosition) -> UITextPosition {
        
        // check if last char is newline
        if let prevPos = position(from: pos, offset: -1) {
            if text(in: textRange(from: prevPos, to: pos)!) == "\n" {
                return pos
            }
        }
        
        // if caret is at document beginning, position() returns nil
        return tokenizer.position(from: pos,
                                  toBoundary: .paragraph,
                                  inDirection: UITextStorageDirection.backward.rawValue) ?? beginningOfDocument
    }
    
    fileprivate func rangeForMarkdownElement(type: MarkdownElementType, enclosingSelection selection: NSRange) -> MarkdownRange? {
        
        let groupStyler = marklightTextStorage.groupStyler
        
        for range in groupStyler.rangesForElementType(type) {
            // selection is contained in range
            if NSEqualRanges(range.wholeRange, NSUnionRange(selection, range.wholeRange)) {
                return range
            }
        }
        return nil
    }
    
    public func markdownElementsForRange(_ range: NSRange?) -> [MarkdownElementType] {
        
        let selection = range ?? selectedRange
        
        let elementTypes: [MarkdownElementType] = [
            .header(.h1), .header(.h2), .header(.h3),
            .italic, .bold, .numberList, .bulletList,
            .code, .quote
        ]
        
        return elementTypes.filter { type -> Bool in
            return self.isMarkdownElement(type: type, activeForSelection: selection)
        }
    }
    
    fileprivate func isMarkdownElement(type: MarkdownElementType, activeForSelection selection: NSRange) -> Bool {
        return rangeForMarkdownElement(type: type, enclosingSelection: selection) != nil
    }
    
    /// Returns all ranges of leading/trailing whitespace exclusively contained
    /// within markdown elements.
    ///
    fileprivate func rangesOfMarkdownWhitespace() -> [NSRange] {
        
        let text = self.text as NSString
        var rangesToDelete = [NSRange]()
        let charSet = CharacterSet.whitespacesAndNewlines.inverted
        
        for range in allMarkdownRanges() {
            
            let contentRange = range.contentRange
            
            // range start of first non whitespace char in content range
            let rangeOfFirstChar = text.rangeOfCharacter(from: charSet, options: [], range: contentRange)
            
            // if not found, then content range contains only whitespace
            if rangeOfFirstChar.location == NSNotFound {
                rangesToDelete.append(contentRange)
                continue
            } else {
                let spaces = rangeOfFirstChar.location - contentRange.location
                if spaces > 0 {
                    rangesToDelete.append(NSMakeRange(contentRange.location, spaces))
                }
            }
            
            // as above, but starting from end of content range
            let rangeOfLastChar = text.rangeOfCharacter(from: charSet, options: .backwards, range: range.contentRange)
            if rangeOfLastChar.location != NSNotFound{
                let spaces = NSMaxRange(contentRange) - NSMaxRange(rangeOfLastChar)
                if spaces > 0 {
                    rangesToDelete.append(NSMakeRange(NSMaxRange(rangeOfLastChar), spaces))
                }
            }
        }
        
        return rangesToDelete
    }
    
    /// Returns all ranges of markdown elements that have zero content or contain
    /// containing only whitespace.
    ///
    fileprivate func rangesOfEmptyMarkdownElements() -> [NSRange] {
        
        var result = [NSRange]()
        
        for range in allMarkdownRanges() {
            if isEmptyMarkdownElement(range) {
                result.append(range.wholeRange)
            }
        }
        
        return result
    }
    
    /// Returns true if the markdown element specified by the given range has a
    /// zero content range or the content text contains only whitespace and/or
    /// other markdown syntax.
    /// - parameter range: the range specifying the markdown element
    ///
    fileprivate func isEmptyMarkdownElement(_ range: MarkdownRange) -> Bool {
        
        let contentRange = range.contentRange

        if contentRange.length == 0 {
            return true
        }
        
        let syntaxColor = style.syntaxAttributes[NSForegroundColorAttributeName] as! UIColor
        
        for index in contentRange.location..<NSMaxRange(contentRange) {
            let char = text[text.index(text.startIndex, offsetBy: index)]
            let color = attributedText.attribute(NSForegroundColorAttributeName, at: index, effectiveRange: nil) as? UIColor
            
            if " \t\n\r".characters.contains(char) || color == syntaxColor {
                continue
            } else {
                return false
            }
        }
        
        return true
    }
    
    /// Returns all syntax ranges of markdown elements that contain only whitespace and
    /// at least one emoji.
    ///
    fileprivate func rangesOfSyntaxForMarkdownEmoji() -> [NSRange] {
        
        var result = [NSRange]()
        
        for range in allMarkdownRanges() {
            let content = text.substring(with: range.contentRange)
            
            // emojis belong to symbols set, so if we split content str by symbols then the
            // number of components - 1 is the number of symbols/emoji
            
            // no emojis
            if (content.components(separatedBy: CharacterSet.symbols).count - 1) == 0 {
                continue
            }
            
            let nonEmojiNonSpaceSet = CharacterSet.symbols.union(CharacterSet.whitespacesAndNewlines).inverted
            let numNonEmojiNonSpace = content.components(separatedBy: nonEmojiNonSpaceSet).count - 1
            
            // only emojis or space
            if numNonEmojiNonSpace == 0 {
                if let preRange = range.preRange { result.append(preRange) }
                if let postRange = range.postRange { result.append(postRange) }
            } else {
                continue
            }
        }
        
        return result
    }
    
    /// Filters the given array of ranges by discarding all ranges that are
    /// nested within at least one other range.
    /// - parameter ranges: an array of ranges to filter
    ///
    fileprivate func flattenRanges(_ ranges: [NSRange]) -> [NSRange] {
        
        // sort by length ascending
        var ranges = ranges.sorted { return $0.length <= $1.length }
        var result = [NSRange]()
        
        // take the largest range
        if let next = ranges.popLast() {
            result.append(next)
        }
        
        // check each remaining range
        outer: while let next = ranges.popLast() {
            for range in result {
                // if it is nested
                if NSEqualRanges(range, NSUnionRange(range, next)) {
                    continue outer
                }
            }
            // non nested range
            result.append(next)
        }
        
        return result
    }
}


// MARK: - Automatic List Insertion

extension MarklightTextView {
    
    public func handleNewLine() {
        
        guard let caretPos = selectedTextRange?.start else { return }
        
        let lineStart = lineStartForTextAtPosition(caretPos)
        let lineTextRange = textRange(from: lineStart, to: caretPos)!
        let location = offset(from: beginningOfDocument, to: lineTextRange.start)
        let length = offset(from: lineTextRange.start, to: lineTextRange.end)
        let lineRange = NSMakeRange(location, length)
        
        // if line is number list element
        if isMarkdownElement(type: .numberList, activeForSelection: lineRange) {
            // non empty number list item
            let regex = try! NSRegularExpression(pattern: "(^\\d+)(?:[.][\\t ]+)(.|[\\t ])+", options: [.anchorsMatchLines])
            
            if let match = regex.firstMatch(in: text, options: [], range: lineRange) {
                let numberStr = text.substring(with: match.rangeAt(1)) as NSString
                nextListNumber = numberStr.integerValue + 1
                needsNewNumberListItem = true

            } else {
                // replace empty list item with newline
                text.deleteCharactersIn(range: lineRange)
                nextListNumber = 1
            }
            
        } else if isMarkdownElement(type: .bulletList, activeForSelection: lineRange) {
            // non empty bullet list item
            let regex = try! NSRegularExpression(pattern: "(^[*+-])(?:[\\t ]+)(.|[\\t ])+", options: [.anchorsMatchLines])
            
            if let match = regex.firstMatch(in: text, options: [], range: lineRange) {
                nextListBullet = text.substring(with: match.rangeAt(1))
                needsNewBulletListItem = true
            } else {
                // replace empty list item with newline
                text.deleteCharactersIn(range: lineRange)
                nextListBullet = "-"
            }
        }
    }
    
    @objc fileprivate func textChangedHandler() {
        if needsNewNumberListItem {
            needsNewNumberListItem = false
            insertSyntaxForMarkdownElement(type: .numberList)
        } else if needsNewBulletListItem {
            needsNewBulletListItem = false
            insertSyntaxForMarkdownElement(type: .bulletList)
        }
    }
    
    @objc public func resetTypingAttributes() {
        typingAttributes = defaultAttributes
    }
}

// MARK: - MarkdownBarViewDelegate

extension MarklightTextView: MarkdownBarViewDelegate {
    
    public func markdownBarView(_ markdownBarView: MarkdownBarView, didSelectElementType type: MarkdownElementType, with sender: IconButton) {
        
        switch type {
        case .header, .numberList, .bulletList:  removeExistingPrefixSyntax()
        default: break
        }
        
        insertSyntaxForMarkdownElement(type: type)
    }
    
    public func markdownBarView(_ markdownBarView: MarkdownBarView, didDeselectElementType type: MarkdownElementType, with sender: IconButton) {
        deleteSyntaxForMarkdownElement(type: type)
    }
    
    private func removeExistingPrefixSyntax() {
        removeExistingHeader()
        removeExistingListItem()
    }
    
    private func removeExistingHeader() {
        
        var currentHeader: MarkdownElementType?
        for header in [MarkdownElementType.header(.h1), .header(.h2), .header(.h3)] {
            if isMarkdownElement(type: header, activeForSelection: selectedRange) {
                currentHeader = header
            }
        }
        
        if let header = currentHeader {
            deleteSyntaxForMarkdownElement(type: header)
        }
    }
    
    private func removeExistingListItem() {
        
        var currentListType: MarkdownElementType?
        if isMarkdownElement(type: .numberList, activeForSelection: selectedRange) {
            currentListType = .numberList
        } else if isMarkdownElement(type: .bulletList, activeForSelection: selectedRange) {
            currentListType = .bulletList
        }
        
        if let type = currentListType {
            deleteSyntaxForMarkdownElement(type: type)
        }
    }
}

extension String {
    
    mutating fileprivate func deleteCharactersIn(range: NSRange) {
        self = (self as NSString).replacingCharacters(in: range, with: "")
    }
    
    fileprivate func substring(with range: NSRange) -> String {
        return (self as NSString).substring(with: range)
    }
}
