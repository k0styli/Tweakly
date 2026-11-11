import AppKit

/// A value above a short caption, for showing several facts side by side.
final class StatCell: NSView {
    private let valueLabel = NSTextField.detailLabel(
        "—",
        font: .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    )
    private let captionLabel = NSTextField.detailLabel(font: .systemFont(ofSize: 10), color: .secondaryLabelColor)

    /// - Parameter key: The colour of what the cell describes in a chart nearby, if there is one.
    init(caption: String, key: NSColor? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        captionLabel.stringValue = caption
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var captionViews: [NSView] = [captionLabel]
        if let key { captionViews.insert(ColorDot(color: key, size: 7), at: 0) }
        let captionRow = NSStackView(views: captionViews)
        captionRow.orientation = .horizontal
        captionRow.spacing = 3
        captionRow.alignment = .centerY

        let column = NSStackView(views: [valueLabel, captionRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func set(_ value: String) {
        valueLabel.setIfChanged(value)
    }

    func setCaption(_ caption: String) {
        captionLabel.setIfChanged(caption)
    }
}

/// Equal columns of cells. An empty view keeps a column free, so that columns line up from row to row.
func statRow(_ cells: [NSView]) -> NSView {
    let row = NSStackView(views: cells)
    row.orientation = .horizontal
    row.distribution = .fillEqually
    row.spacing = 8
    row.edgeInsets = NSEdgeInsetsZero
    row.translatesAutoresizingMaskIntoConstraints = false
    return row
}

/// A legend row: colour, name and two values, such as a share and an amount. The values sit in fixed
/// columns, so the divider between them lines up across rows however many digits each value has.
final class LegendRow: NSView {
    private static let columnSpacing: CGFloat = 8

    private let dot: ColorDot

    private let firstLabel = NSTextField.detailLabel(
        "—",
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        alignment: .right
    )
    private let secondLabel = NSTextField.detailLabel(
        "—",
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        alignment: .right
    )

    /// - Parameter widestSecond: The longest second value to expect, which sets that column's width.
    init(title: String, key: NSColor, widestSecond: String) {
        dot = ColorDot(color: key, size: 8)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField.detailLabel(title, color: .secondaryLabelColor)
        let divider = RowDivider()
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [dot, titleLabel, firstLabel, divider, secondLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: firstLabel.leadingAnchor, constant: -8),

            secondLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            secondLabel.widthAnchor.constraint(equalToConstant: secondLabel.requiredWidth(for: widestSecond)),
            secondLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            divider.trailingAnchor.constraint(equalTo: secondLabel.leadingAnchor, constant: -Self.columnSpacing),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 11),

            firstLabel.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -Self.columnSpacing),
            firstLabel.widthAnchor.constraint(equalToConstant: firstLabel.requiredWidth(for: Format.percent(1.0))),
            firstLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// For a part of a chart whose colour changes with its state.
    func setKey(_ color: NSColor) {
        dot.color = color
    }

    func update(first: String, second: String) {
        firstLabel.setIfChanged(first)
        secondLabel.setIfChanged(second)
    }
}
