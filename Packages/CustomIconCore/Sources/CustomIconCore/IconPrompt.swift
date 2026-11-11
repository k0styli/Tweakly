/// The prompt that gets ChatGPT, Claude or a similar model to draw an icon that fits this app. It stays in English
/// whatever the app's language, because models follow a technical brief most reliably in it, and it has no part in the
/// interface. The description goes in as the person wrote it.
public enum IconPrompt {
    public static let placeholder = "{DESCRIPTION}"

    public static func make(description: String, isAnimated: Bool, isColoured: Bool) -> String {
        let cleaned = description.split(whereSeparator: \.isNewline).joined(separator: " ")
        let subject = cleaned.allSatisfy(\.isWhitespace) ? placeholder : cleaned
        return [
            intro(subject: subject, isAnimated: isAnimated),
            deliver,
            canvas,
            isColoured ? colourStyle : singleColourStyle,
            shapes,
            isAnimated ? animation : still,
            checks(isAnimated: isAnimated),
            skeleton(isAnimated: isAnimated),
        ].joined(separator: "\n\n")
    }

    private static func intro(subject: String, isAnimated: Bool) -> String {
        """
        You are drawing \(isAnimated ? "one animated icon" : "one icon") for the macOS menu bar, for an app called \
        Tweakly. It sits next to the system's own icons all day, so it has to look as if Apple drew it.

        WHAT TO DRAW
        \(subject)
        """
    }

    private static let deliver = """
        WHAT TO DELIVER
        One SVG file, written by you as vector shapes. Do not generate a picture with an image model and do not trace one: \
        at this size only clean, deliberate shapes survive. If you can create files, attach it as tweakly-icon.svg. In any \
        case also show the complete SVG in one code block, so that it can be copied. Say nothing else: no explanation and \
        no alternatives.
        """

    private static let canvas = """
        CANVAS
        - The root is <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 W 36">, with no other size attributes.
        - The height is always 36 units. W is a whole number from 36 to 72: 36 for a compact subject, 48 to 64 for a wide \
        one such as a running animal or a car.
        - The subject fills the canvas from y=2 to y=34 and comes within 2 units of the left and right edges. Empty margins \
        only make it smaller.
        - It is shown 16 points tall, so one unit is half a point: one physical pixel on a Retina display. Nothing thinner \
        than 3 units and no gap narrower than 3 units will be visible.
        """

    private static let singleColourStyle = """
        STYLE
        - A solid silhouette in one colour: every shape is #000000, as its fill, or as its stroke with fill="none". The app \
        recolours it to match the menu bar, so shades do not exist here: no greys, no opacity, no gradients.
        - Inner details such as an eye are real holes, made with fill-rule="evenodd" and at least 3 units across.
        - Shaped like an SF Symbol: bold, simple and geometric, with smooth curves, slightly rounded corners and parts of \
        even thickness.
        - It must read from its outline alone. Exaggerate what identifies the subject, such as the ears and tail of a cat, \
        and leave out everything else.
        - No text, background, frame or shadow.
        """

    private static let colourStyle = """
        STYLE
        - At most 3 flat colours, written as #RRGGBB, each clearly visible on both a light and a dark menu bar: nothing \
        close to black or white. No opacity, gradients or shadows.
        - Inner details such as an eye are shapes or real holes, at least 3 units across.
        - Shaped like an SF Symbol: bold, simple and geometric, with smooth curves, slightly rounded corners and parts of \
        even thickness.
        - It must read from its outline alone. Exaggerate what identifies the subject, such as the ears and tail of a cat, \
        and leave out everything else.
        - No text, background or frame.
        """

    private static let shapes = """
        WHAT THE FILE MAY CONTAIN
        Only svg, g, defs, use, path, circle, ellipse, rect, polygon, polyline and line, with plain attributes and static \
        transform attributes. Strokes are allowed if they are at least 3 units wide with round caps and joins. No CSS, \
        classes, style elements, script, image, text, filter, mask, clipPath, gradients, foreignObject, animate or comments.
        """

    private static let animation = """
        ANIMATION
        - The file holds every frame itself. There is no CSS or SMIL animation: the app plays the frames in turn.
        - The root has data-fps="12": how many frames a second at normal speed, from 6 to 24.
        - Each frame is a direct child of the root: <g data-frame="1">, <g data-frame="2"> and so on, without display or \
        visibility attributes. Use 6 to 12 frames: a few strong poses look better than many similar ones.
        - Each frame draws the whole subject. Put what does not change in <defs> once and <use href="#body"/> it in every \
        frame, so that it stays exactly the same.
        - It loops without a seam: the last frame leads into the first with no jump.
        - It stays on the spot. A runner runs in place, with its body in the same place and its feet on the same ground \
        line in every frame. The subject keeps its size, and the whole of it may bob by at most 2 units.
        - Parts that come together stay apart by at least 3 units: legs under a body must not melt into one blob, because \
        at this size a frame that loses its outline looks like a mistake. Leave out a pose rather than let that happen.
        - The app plays it from half speed to four times the speed, faster the busier the computer is. So the movement has \
        to read at any speed: moving parts shift at least 3 units from frame to frame, with no pauses or held poses.
        - If the subject has no natural movement of its own, give it one simple cycle that suits it: turning, flapping, \
        pulsing or bouncing.
        """

    private static let still = """
        A SINGLE DRAWING
        The file holds one drawing with no frames and no animation.
        """

    private static func checks(isAnimated: Bool) -> String {
        var lines = [
            "BEFORE YOU ANSWER",
            "- Imagine it 16 points tall on a dark menu bar. Can someone tell what it is in a second? If not, simplify.",
            "- The viewBox height is 36, and nothing is cut off at the edges.",
            "- Every shape is closed and every attribute value is quoted, so that it parses as XML.",
        ]
        if isAnimated {
            lines.append(
                "- Compare the frames in turn: the body does not drift, and frame 1 follows the last one smoothly.")
        }
        return lines.joined(separator: "\n")
    }

    private static func skeleton(isAnimated: Bool) -> String {
        if isAnimated {
            return """
                THE SHAPE OF THE FILE
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 56 36" data-fps="12">
                  <defs><path id="body" d="..." fill="#000000"/></defs>
                  <g data-frame="1"><use href="#body"/><path d="..." fill="#000000"/></g>
                  <g data-frame="2"><use href="#body"/><path d="..." fill="#000000"/></g>
                </svg>
                """
        }
        return """
            THE SHAPE OF THE FILE
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36">
              <path d="..." fill="#000000"/>
            </svg>
            """
    }
}
