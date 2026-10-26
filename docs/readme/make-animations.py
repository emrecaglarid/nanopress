# Draws the README animations of a mock desktop, frame by frame. Run: python3 docs/readme/make-animations.py docs/readme (needs Pillow and ffmpeg)
import os, sys, subprocess, shutil
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2                      # drawn at 2x, scaled down for smooth edges
W, H = 960, 540
FPS = 30
OUT = sys.argv[1]
TMP = os.path.join(os.path.dirname(__file__), 'frames')
ACCENT = (10, 132, 255)
FONT = '/System/Library/Fonts/SFNS.ttf'

def font(size, weight=400):
    f = ImageFont.truetype(FONT, size * S)
    # Width, optical size, grade, weight
    f.set_variation_by_axes([100, min(max(size, 17), 96), 400, weight])
    return f

def ease(t): t = max(0, min(1, t)); return 1 - (1 - t) ** 3
def ease_io(t): t = max(0, min(1, t)); return 3 * t * t - 2 * t * t * t
def lerp(a, b, t): return a + (b - a) * t
def lerp_rect(a, b, t): return tuple(lerp(x, y, t) for x, y in zip(a, b))
def sc(r): return tuple(v * S for v in r)

def background():
    top, bottom = (43, 51, 64), (91, 75, 107)
    img = Image.new('RGB', (W * S, H * S))
    d = ImageDraw.Draw(img)
    for y in range(H * S):
        t = y / (H * S)
        d.line([(0, y), (W * S, y)], fill=tuple(int(lerp(a, b, t)) for a, b in zip(top, bottom)))
    return img
BG = background()

APPS = {
    'Dia': ((255, 196, 61), 'Kytöniitty listing'),
    'Slack': ((97, 31, 105), '#design'),
    'Ghostty': ((40, 42, 48), '~/nanopress'),
    'Mail': ((30, 120, 245), 'Inbox'),
    'Notes': ((242, 190, 40), 'Groceries'),
}

def shadow(img, rect, radius=14, blur=18, alpha=90, offset=8):
    x, y, w, h = sc(rect)
    layer = Image.new('L', img.size, 0)
    ImageDraw.Draw(layer).rounded_rectangle([x, y + offset * S, x + w, y + h + offset * S], radius * S, fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(blur * S))
    img.paste(Image.new('RGB', img.size, (0, 0, 0)), (0, 0), layer)

def window(img, rect, app, alpha=255, lift=False):
    x, y, w, h = rect
    if w < 4 or h < 4: return
    shadow(img, rect, blur=24 if lift else 14, alpha=140 if lift else 80, offset=12 if lift else 6)
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    X, Y, Wd, Hd = sc(rect)
    r = 12 * S
    d.rounded_rectangle([X, Y, X + Wd, Y + Hd], r, fill=(252, 252, 253, 255), outline=(200, 200, 206, 255), width=S)
    # Title bar
    tb = 34 * S
    d.rounded_rectangle([X + S, Y + S, X + Wd - S, Y + tb], r, fill=(236, 236, 239, 255))
    d.rectangle([X + S, Y + tb - r, X + Wd - S, Y + tb], fill=(236, 236, 239, 255))
    d.line([X, Y + tb, X + Wd, Y + tb], fill=(214, 214, 219, 255), width=S)
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx, cy = X + (16 + i * 18) * S, Y + tb / 2
        d.ellipse([cx - 6 * S, cy - 6 * S, cx + 6 * S, cy + 6 * S], fill=c + (255,))
    color, title = APPS[app]
    if w > 150:
        ix = X + 76 * S
        d.rounded_rectangle([ix, Y + tb / 2 - 8 * S, ix + 16 * S, Y + tb / 2 + 8 * S], 4 * S, fill=color + (255,))
        d.text((ix + 22 * S, Y + tb / 2), app, font=font(12, 600), fill=(40, 40, 46, 255), anchor='lm')
    # Content: a sidebar in the app's color, then lines
    cy = Y + tb + 14 * S
    side = min(90 * S, Wd * 0.25)
    d.rectangle([X + S, Y + tb + S, X + side, Y + Hd - r], fill=tuple(int(c * 0.18 + 255 * 0.82) for c in color) + (255,))
    while cy + 10 * S < Y + Hd - 16 * S:
        lw = (Wd - side - 32 * S) * (0.9 if (cy // (22 * S)) % 3 else 0.55)
        d.rounded_rectangle([X + side + 16 * S, cy, X + side + 16 * S + lw, cy + 8 * S], 4 * S, fill=(226, 226, 231, 255))
        cy += 22 * S
    if alpha < 255:
        layer.putalpha(layer.getchannel('A').point(lambda v: v * alpha // 255))
    img.paste(layer, (0, 0), layer)

def region(img, rect, fill_alpha=70, outline=255, dashed=False, radius=12):
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    X, Y, Wd, Hd = sc(rect)
    if dashed:
        d.rounded_rectangle([X, Y, X + Wd, Y + Hd], radius * S, fill=(255, 255, 255, 30))
        dash = 10 * S
        for edge in [((X, Y), (X + Wd, Y)), ((X + Wd, Y), (X + Wd, Y + Hd)), ((X + Wd, Y + Hd), (X, Y + Hd)), ((X, Y + Hd), (X, Y))]:
            (x1, y1), (x2, y2) = edge
            length = max(abs(x2 - x1), abs(y2 - y1)); n = int(length // (dash * 2))
            for i in range(n + 1):
                t1, t2 = i * 2 * dash / length, min((i * 2 + 1) * dash / length, 1)
                if t1 > 1: break
                d.line([lerp(x1, x2, t1), lerp(y1, y2, t1), lerp(x1, x2, t2), lerp(y1, y2, t2)], fill=(255, 255, 255, 170), width=2 * S)
    else:
        d.rounded_rectangle([X, Y, X + Wd, Y + Hd], radius * S, fill=ACCENT + (fill_alpha,), outline=ACCENT + (outline,), width=2 * S)
    img.paste(layer, (0, 0), layer)

def card(img, center, text, alpha=255):
    f = font(14, 600)
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    tw = d.textlength(text, font=f)
    cx, cy = center[0] * S, center[1] * S
    pw, ph = tw + 32 * S, 36 * S
    d.rounded_rectangle([cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2], ph / 2, fill=(30, 30, 34, int(230 * alpha / 255)))
    d.text((cx, cy), text, font=f, fill=(255, 255, 255, alpha), anchor='mm')
    img.paste(layer, (0, 0), layer)

def cursor(img, pos, pressed=False):
    x, y = pos[0] * S, pos[1] * S
    k = S * (0.9 if pressed else 1)
    pts = [(0, 0), (0, 17), (4, 13), (7, 20), (10, 19), (7, 12), (12, 12)]
    poly = [(x + px * k, y + py * k) for px, py in pts]
    d = ImageDraw.Draw(img)
    d.polygon(poly, fill=(0, 0, 0), outline=(255, 255, 255))
    d.line(poly + [poly[0]], fill=(255, 255, 255), width=int(1.5 * S))

def save(frames, name):
    if os.path.exists(TMP): shutil.rmtree(TMP)
    os.makedirs(TMP)
    for i, f in enumerate(frames):
        f.resize((W, H), Image.LANCZOS).save(os.path.join(TMP, f'{i:04d}.png'))
    out = os.path.join(OUT, name)
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-framerate', str(FPS), '-i', os.path.join(TMP, '%04d.png'),
                    '-vf', 'split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5',
                    '-loop', '0', out], check=True)
    print(out, os.path.getsize(out) // 1024, 'KB')

# MARK: Drag and drop

def drag_frames():
    M, G = 12, 10
    left = (M, M, 464, H - 2 * M)
    rx = M + 464 + G
    rw = W - M - rx
    top_right = (rx, M, rw, (H - 2 * M - G) / 2)
    bottom_right = (rx, M + (H - 2 * M - G) / 2 + G, rw, (H - 2 * M - G) / 2)
    # After the drop: Ghostty left of Dia, Slack takes the whole right
    half = (464 - G) / 2
    ghostty_end = (M, M, half, H - 2 * M)
    dia_end = (M + half + G, M, half, H - 2 * M)
    slack_end = (rx, M, rw, H - 2 * M)

    grab = (bottom_right[0] + 200, bottom_right[1] + 17)

    # While dragged, the window shrinks around the cursor, so that the preview under it stays visible
    def lifted_rect(cur, i):
        k = lerp(1, 0.42, ease((i - 18) / 10))
        w, h = bottom_right[2] * k, bottom_right[3] * k
        gx = (grab[0] - bottom_right[0]) * k
        gy = (grab[1] - bottom_right[1]) * k
        return (cur[0] - gx, cur[1] - gy, w, h)
    target = (95, 270)
    frames = []
    total = 150
    for i in range(total):
        img = BG.copy()
        t_move = (i - 18) / 30            # dragging
        t_drop = (i - 62) / 14            # settling
        dragging = 18 <= i < 62
        dropped = i >= 62
        if i < 14:
            cur = (lerp(760, grab[0], ease_io(i / 14)), lerp(470, grab[1], ease_io(i / 14)))
        elif not dropped:
            cur = (lerp(grab[0], target[0], ease_io(t_move)), lerp(grab[1], target[1], ease_io(t_move)))
        else:
            cur = target
        over_edge = dragging and cur[0] < 210
        if not dropped:
            window(img, left, 'Dia')
            window(img, top_right, 'Slack')
            if dragging:
                region(img, bottom_right, dashed=True)
            else:
                window(img, bottom_right, 'Ghostty')
            if over_edge:
                region(img, dia_end, fill_alpha=0, outline=150)
                region(img, slack_end, fill_alpha=0, outline=150)
                region(img, ghostty_end, fill_alpha=80)
            if dragging:
                window(img, lifted_rect(cur, i), 'Ghostty', alpha=235, lift=True)
            if over_edge:
                card(img, (ghostty_end[0] + ghostty_end[2] / 2, H - 60), 'Left of Dia')
        else:
            t = ease(t_drop)
            lifted = lifted_rect(target, 61)
            window(img, lerp_rect(left, dia_end, t), 'Dia')
            window(img, lerp_rect(top_right, slack_end, t), 'Slack')
            window(img, lerp_rect(lifted, ghostty_end, t), 'Ghostty')
            if i > 118:
                cur = (lerp(target[0], 760, ease_io((i - 118) / 24)), lerp(target[1], 470, ease_io((i - 118) / 24)))
        cursor(img, cur, pressed=dragging)
        frames.append(img)
    # Fade back to the start so the loop doesn't jump
    first = frames[0]
    for k in range(10):
        frames.append(Image.blend(frames[-1 - k * 0] if k == 0 else frames[-1], first, (k + 1) / 10))
    return frames

# MARK: Tabs

def tabs_frames():
    M, G = 12, 10
    left = (M, M, 464, H - 2 * M)
    rx = M + 464 + G
    rw = W - M - rx
    tab_h, tab_gap = 26, 4
    stack = (rx, M, rw, H - 2 * M - tab_h - tab_gap)
    order = ['Slack', 'Mail', 'Notes']
    f = font(11, 600)
    f2 = font(11, 400)
    probe = ImageDraw.Draw(Image.new('RGB', (10, 10)))

    def tab_rects():
        x = rx
        rects = []
        for app in order:
            text_w = (probe.textlength(app, font=f) + probe.textlength('  ' + APPS[app][1], font=f2)) / S
            w = 10 + 16 + 6 + text_w + 10
            rects.append((x, H - M - tab_h, w, tab_h))
            x += w + 3
        rects.append((x, H - M - tab_h, 30, tab_h))
        return rects

    def draw_tabs(img, front, hovered, show_plus, badge):
        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        rects = tab_rects()
        n = len(order)
        for idx, (app, rect) in enumerate(zip(order, rects)):
            X, Y, Wd, Hd = sc(rect)
            is_front = app == front
            base = (236, 236, 239)
            fill = tuple(int(lerp(c, a, 0.16)) for c, a in zip(base, ACCENT)) if is_front else (tuple(c - 14 for c in base) if hovered == app else base)
            outer, inner = 8 * S, 3 * S
            last = idx == n - 1 and not show_plus
            radii = (outer if idx == 0 else inner, outer if last else inner)
            # Leading and trailing corners differ: draw as two rounded rects joined
            d.rounded_rectangle([X, Y, X + Wd, Y + Hd], radii[0], fill=fill + (255,))
            d.rounded_rectangle([X + Wd / 2, Y, X + Wd, Y + Hd], radii[1], fill=fill + (255,))
            d.rectangle([X + radii[0], Y, X + Wd - radii[1], Y + Hd], fill=fill + (255,))
            color, title = APPS[app]
            ix = X + 10 * S
            d.rounded_rectangle([ix, Y + Hd / 2 - 8 * S, ix + 16 * S, Y + Hd / 2 + 8 * S], 4 * S, fill=color + (255,))
            if badge == app and not is_front:
                d.ellipse([ix + 11 * S, Y + Hd / 2 - 12 * S, ix + 20 * S, Y + Hd / 2 - 3 * S], fill=(255, 59, 48, 255), outline=(236, 236, 239, 255), width=S)
            tx = ix + 22 * S
            text_color = ACCENT if is_front else (60, 60, 67)
            d.text((tx, Y + Hd / 2), app, font=f, fill=text_color + (255,), anchor='lm')
            tx += d.textlength(app, font=f)
            d.text((tx, Y + Hd / 2), '  ' + title, font=f2, fill=(text_color if is_front else (120, 120, 128)) + (255,), anchor='lm')
        if show_plus:
            X, Y, Wd, Hd = sc(rects[-1])
            d.rounded_rectangle([X, Y, X + Wd, Y + Hd], 8 * S, fill=(236, 236, 239, 255))
            d.rounded_rectangle([X, Y, X + Wd / 2, Y + Hd], 3 * S, fill=(236, 236, 239, 255))
            cx, cy = X + Wd / 2, Y + Hd / 2
            d.line([cx - 6 * S, cy, cx + 6 * S, cy], fill=(90, 90, 98, 255), width=2 * S)
            d.line([cx, cy - 6 * S, cx, cy + 6 * S], fill=(90, 90, 98, 255), width=2 * S)
        img.paste(layer, (0, 0), layer)

    rects = tab_rects()
    def center(i): r = rects[i]; return (r[0] + r[2] / 2, r[1] + r[3] / 2)
    keys = [  # (frame, cursor position)
        (0, (700, 300)), (16, center(1)), (40, center(1)), (58, center(2)), (82, center(2)),
        (100, (rects[3][0] + 15, rects[3][1] + 13)), (124, (rects[3][0] + 15, rects[3][1] + 13)), (146, (700, 300)), (160, (700, 300)),
    ]
    def cursor_at(i):
        for (f1, p1), (f2, p2) in zip(keys, keys[1:]):
            if f1 <= i <= f2:
                t = ease_io((i - f1) / max(f2 - f1, 1))
                return (lerp(p1[0], p2[0], t), lerp(p1[1], p2[1], t))
        return keys[-1][1]

    frames = []
    for i in range(160):
        img = BG.copy()
        front = 'Slack' if i < 22 else 'Mail' if i < 64 else 'Notes'
        previous = {'Mail': 'Slack', 'Notes': 'Mail'}.get(front)
        switched_at = 22 if front == 'Mail' else 64
        cur = cursor_at(i)
        hovered = None
        for app, r in zip(order, rects):
            if r[0] <= cur[0] <= r[0] + r[2] and r[1] <= cur[1] <= r[1] + r[3]: hovered = app
        on_bar = rects[0][0] <= cur[0] <= rects[3][0] + rects[3][2] and rects[0][1] - 4 <= cur[1] <= rects[0][1] + rects[0][3] + 4
        window(img, left, 'Dia')
        window(img, stack, front)
        if previous and i - switched_at < 6:
            # Brief crossfade from the window that was in front
            old = BG.copy(); window(old, left, 'Dia'); window(old, stack, previous)
            img = Image.blend(old, img, (i - switched_at + 1) / 6)
        draw_tabs(img, front, hovered, on_bar, badge='Mail')
        cursor(img, cur, pressed=i in (20, 21, 62, 63))
        frames.append(img)
    return frames

if __name__ == '__main__':
    which = sys.argv[2:] or ['drag', 'tabs']
    if 'drag' in which: save(drag_frames(), 'drag-and-drop.gif')
    if 'tabs' in which: save(tabs_frames(), 'stack-tabs.gif')
