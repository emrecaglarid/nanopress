# Draws the README animations of a mock desktop, frame by frame. Run: python3 docs/readme/make-animations.py docs/readme (needs Pillow and ffmpeg)
import os, sys, subprocess, shutil, tempfile
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2                      # drawn at 2x, scaled down for smooth edges
W, H = 960, 540
FPS = 30
OUT = sys.argv[1]
TMP = os.path.join(tempfile.gettempdir(), 'nanopress-readme-frames')  # Frames before they become a GIF
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
    'Ghostty': ((40, 42, 48), 'zsh'),
    'Mail': ((30, 120, 245), 'Inbox'),
    'Notes': ((242, 190, 40), 'Ideas'),
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

    # The box in the middle of the window under the cursor: stack on its left half, swap on its right
    def middle_box(r):
        x, y, w, h = r
        bw = min(min(max(w * 0.36, 140), 240), w * 0.6)
        bh = min(min(max(h * 0.22, 72), 120), h * 0.5)
        return (x + (w - bw) / 2, y + (h - bh) / 2, bw, bh)

    # The rest of the window splits toward its nearest edge, along the diagonals
    def zone(r, cur):
        x, y, w, h = r
        fx, fy = (cur[0] - x) / w, (cur[1] - y) / h
        side = min([('left', fx), ('right', 1 - fx), ('top', fy), ('bottom', 1 - fy)], key=lambda e: e[1])[0]
        rect = {'left': (x, y, w / 2, h), 'right': (x + w / 2, y, w / 2, h),
                'top': (x, y, w, h / 2), 'bottom': (x, y + h / 2, w, h / 2)}[side]
        title = {'left': 'Left of Dia', 'right': 'Right of Dia', 'top': 'Above Dia', 'bottom': 'Below Dia'}[side]
        return rect, title

    def hints(img, target, cur):
        X, Y, Wd, Hd = sc(target)
        box = (int(X), int(Y), int(X + Wd), int(Y + Hd))
        # Blurred and a little dimmed, so the hints read over the window's content
        muted = img.crop(box).filter(ImageFilter.GaussianBlur(8 * S))
        muted = Image.blend(muted, Image.new('RGB', muted.size, (0, 0, 0)), 0.12)
        mask = Image.new('L', muted.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, muted.size[0], muted.size[1]], 12 * S, fill=255)
        img.paste(muted, box[:2], mask)

        rect, title = zone(target, cur)
        mb = middle_box(target)
        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        zx, zy, zw, zh = sc((rect[0] + 4, rect[1] + 4, rect[2] - 8, rect[3] - 8))
        d.rounded_rectangle([zx, zy, zx + zw, zy + zh], 12 * S, fill=ACCENT + (140,), outline=(255, 255, 255, 150), width=int(1.5 * S))
        bx, by, bw, bh = sc(mb)
        d.rounded_rectangle([bx, by, bx + bw, by + bh], 12 * S, fill=(0, 0, 0, 0))  # The box stays clear of the blue
        img.paste(layer, (0, 0), layer)

        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        ink = (30, 30, 34)
        d.rounded_rectangle([bx, by, bx + bw, by + bh], 12 * S, outline=ink + (128,), width=int(1.5 * S))
        d.line([bx + bw / 2, by, bx + bw / 2, by + bh], fill=ink + (128,), width=int(1.5 * S))
        d.text((bx + bw / 4, by + bh / 2), 'Stack', font=font(13, 600), fill=ink + (215,), anchor='mm')
        d.text((bx + bw * 3 / 4, by + bh / 2), 'Swap', font=font(13, 600), fill=ink + (215,), anchor='mm')
        arrow = font(20, 600)
        for ch, (ax, ay) in [('↑', (X + Wd / 2, Y + 36 * S)), ('↓', (X + Wd / 2, Y + Hd - 36 * S)),
                             ('←', (X + 36 * S, Y + Hd / 2)), ('→', (X + Wd - 36 * S, Y + Hd / 2))]:
            d.text((ax, ay), ch, font=arrow, fill=ink + (190,), anchor='mm')
        d.text((zx + zw / 2, zy + min(120 * S, zh * 0.22)), title, font=font(15, 600), fill=(255, 255, 255, 255), anchor='mm')
        img.paste(layer, (0, 0), layer)

    keys = [(0, (760, 470)), (14, grab), (18, grab), (32, (420, 190)), (42, (250, 150)), (54, (95, 220)), (66, (95, 220))]
    def cursor_at(i):
        for (f1, p1), (f2, p2) in zip(keys, keys[1:]):
            if f1 <= i <= f2:
                t = ease_io((i - f1) / max(f2 - f1, 1))
                return (lerp(p1[0], p2[0], t), lerp(p1[1], p2[1], t))
        return keys[-1][1]

    frames = []
    total = 154
    drop = 66
    for i in range(total):
        img = BG.copy()
        cur = cursor_at(i)
        dragging = 18 <= i < drop
        if i < drop:
            window(img, left, 'Dia')
            window(img, top_right, 'Slack')
            if dragging:
                region(img, bottom_right, dashed=True)
            else:
                window(img, bottom_right, 'Ghostty')
            over_dia = dragging and cur[0] < left[0] + left[2]
            if over_dia:
                hints(img, left, cur)
            if dragging:
                window(img, lifted_rect(cur, i), 'Ghostty', alpha=235, lift=True)
        else:
            t = ease((i - drop) / 14)
            lifted = lifted_rect(cur, drop - 1)
            window(img, lerp_rect(left, dia_end, t), 'Dia')
            window(img, lerp_rect(top_right, slack_end, t), 'Slack')
            window(img, lerp_rect(lifted, ghostty_end, t), 'Ghostty')
            if i > 122:
                cur = (lerp(cur[0], 760, ease_io((i - 122) / 24)), lerp(cur[1], 470, ease_io((i - 122) / 24)))
        cursor(img, cur, pressed=dragging)
        frames.append(img)
    # Fade back to the start so the loop doesn't jump
    first = frames[0]
    for k in range(10):
        frames.append(Image.blend(frames[-1], first, (k + 1) / 10))
    return frames

# MARK: Tabs

def tabs_frames():
    M, G = 12, 10
    left = (M, M, 464, H - 2 * M)
    rx = M + 464 + G
    rw = W - M - rx
    tab_h = 28
    stack = (rx, M, rw, H - 2 * M - tab_h - 4)
    f = font(11, 600)
    f2 = font(11, 400)
    probe = ImageDraw.Draw(Image.new('RGB', (10, 10)))

    def tab_rects(order):
        x = rx
        rects = []
        for app in order:
            text_w = (probe.textlength(app, font=f) + probe.textlength('  ' + APPS[app][1], font=f2)) / S
            w = 10 + 16 + 6 + text_w + 10
            rects.append((x, H - M - tab_h, w, tab_h))
            x += w + 2
        rects.append((x, H - M - tab_h, 28, tab_h))  # "+"
        return rects

    def draw_tabs(img, order, front, hovered, plus_hovered, badge):
        rects = tab_rects(order)
        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        # One strip of dark glass, as wide as its tabs
        X0, Y0 = rects[0][0] * S, rects[0][1] * S
        X1, Y1 = (rects[-1][0] + rects[-1][2]) * S, (rects[-1][1] + rects[-1][3]) * S
        under = img.crop((int(X0), int(Y0), int(X1), int(Y1))).filter(ImageFilter.GaussianBlur(10 * S))
        under = Image.blend(under, Image.new('RGB', under.size, (20, 20, 24)), 0.45)
        mask = Image.new('L', under.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, under.size[0], under.size[1]], 9 * S, fill=255)
        img.paste(under, (int(X0), int(Y0)), mask)
        d.rounded_rectangle([X0, Y0, X1, Y1], 9 * S, outline=(255, 255, 255, 40), width=S)
        for app, rect in zip(order, rects):
            is_front = app == front
            X, Y, Wd, Hd = sc(rect)
            if is_front:
                d.rounded_rectangle([X, Y, X + Wd, Y + Hd], 9 * S, fill=(245, 245, 247, 255))
            elif hovered == app:
                d.rounded_rectangle([X, Y, X + Wd, Y + Hd], 9 * S, fill=(255, 255, 255, 22))
            color, title = APPS[app]
            ix = X + 10 * S
            d.rounded_rectangle([ix, Y + Hd / 2 - 8 * S, ix + 16 * S, Y + Hd / 2 + 8 * S], 4 * S, fill=color + (255,))
            if badge == app and not is_front:
                d.ellipse([ix + 11 * S, Y + Hd / 2 - 12 * S, ix + 20 * S, Y + Hd / 2 - 3 * S], fill=(255, 59, 48, 255), outline=(60, 60, 66, 255), width=S)
            tx = ix + 22 * S
            d.text((tx, Y + Hd / 2), app, font=f, fill=((20, 20, 24) if is_front else (225, 225, 230)) + (255,), anchor='lm')
            tx += d.textlength(app, font=f)
            d.text((tx, Y + Hd / 2), '  ' + title, font=f2, fill=((110, 110, 118) if is_front else (160, 160, 168)) + (255,), anchor='lm')
        rect = rects[-1]
        X, Y, Wd, Hd = sc(rect)
        if plus_hovered:
            d.rounded_rectangle([X, Y, X + Wd, Y + Hd], 9 * S, fill=(255, 255, 255, 22))
        cx, cy = X + Wd / 2, Y + Hd / 2
        d.line([cx - 5 * S, cy, cx + 5 * S, cy], fill=(200, 200, 206, 255), width=2 * S)
        d.line([cx, cy - 5 * S, cx, cy + 5 * S], fill=(200, 200, 206, 255), width=2 * S)
        img.paste(layer, (0, 0), layer)

    # The "Bring here" menu: every window outside the stack, where it is in quieter text
    MENU_ITEMS = [('Dia', None), ('Ghostty', 'Workspace 2'), ('Calendar', 'Minimized')]
    APPS.setdefault('Calendar', ((255, 69, 58), 'October'))
    item_h, menu_w = 26, 270

    def menu_rect(plus):
        # Opens above "+", shifted left where it would run off the screen, like a real menu
        h = 8 + 22 + item_h * len(MENU_ITEMS) + 6
        return (min(plus[0] - 10, W - M - menu_w), plus[1] - h - 6, menu_w, h)

    def item_rect(menu, i):
        return (menu[0] + 5, menu[1] + 8 + 22 + item_h * i, menu[2] - 10, item_h)

    def draw_menu(img, menu, highlighted, alpha):
        shadow(img, menu, radius=10, blur=16, alpha=int(110 * alpha / 255), offset=6)
        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        X, Y, Wd, Hd = sc(menu)
        d.rounded_rectangle([X, Y, X + Wd, Y + Hd], 10 * S, fill=(246, 246, 248, 250), outline=(205, 205, 210, 255), width=S)
        d.text((X + 14 * S, Y + 19 * S), 'Bring here', font=font(11, 600), fill=(128, 128, 136, 255), anchor='lm')
        for i, (app, place) in enumerate(MENU_ITEMS):
            IX, IY, IW, IH = sc(item_rect(menu, i))
            on = i == highlighted
            if on: d.rounded_rectangle([IX, IY, IX + IW, IY + IH], 5 * S, fill=ACCENT + (255,))
            color, title = APPS[app]
            d.rounded_rectangle([IX + 9 * S, IY + IH / 2 - 8 * S, IX + 25 * S, IY + IH / 2 + 8 * S], 4 * S, fill=color + (255,))
            text = f'{app}: {title}'
            d.text((IX + 33 * S, IY + IH / 2), text, font=font(13, 400), fill=((255, 255, 255) if on else (30, 30, 34)) + (255,), anchor='lm')
            if place:
                tx = IX + 33 * S + d.textlength(text, font=font(13, 400)) + 8 * S
                d.text((tx, IY + IH / 2), place, font=font(13, 400), fill=((225, 235, 255) if on else (130, 130, 138)) + (255,), anchor='lm')
        if alpha < 255:
            layer.putalpha(layer.getchannel('A').point(lambda v: v * alpha // 255))
        img.paste(layer, (0, 0), layer)

    start = ['Slack', 'Mail', 'Notes']
    after = start + ['Ghostty']
    rects = tab_rects(start)
    def center(r): return (r[0] + r[2] / 2, r[1] + r[3] / 2)
    plus = center(rects[3])
    menu = menu_rect(rects[3])
    ghostty_item = center(item_rect(menu, 1))
    keys = [  # (frame, cursor position)
        (0, (700, 300)), (16, center(rects[1])), (40, center(rects[1])), (58, center(rects[2])), (80, center(rects[2])),
        (98, plus), (110, plus), (128, ghostty_item), (142, ghostty_item), (176, (700, 300)), (200, (700, 300)),
    ]
    def cursor_at(i):
        for (f1, p1), (f2, p2) in zip(keys, keys[1:]):
            if f1 <= i <= f2:
                t = ease_io((i - f1) / max(f2 - f1, 1))
                return (lerp(p1[0], p2[0], t), lerp(p1[1], p2[1], t))
        return keys[-1][1]

    def scene(front, order):
        img = BG.copy()
        window(img, left, 'Dia')
        window(img, stack, front)
        return img

    frames = []
    for i in range(200):
        order = start if i < 142 else after
        front = 'Slack' if i < 22 else 'Mail' if i < 64 else 'Notes' if i < 142 else 'Ghostty'
        previous = {'Mail': 'Slack', 'Notes': 'Mail', 'Ghostty': 'Notes'}.get(front)
        switched_at = {'Mail': 22, 'Notes': 64, 'Ghostty': 142}.get(front, 0)
        cur = cursor_at(i)
        rects_now = tab_rects(order)
        hovered = None
        for app, r in zip(order, rects_now):
            if r[0] <= cur[0] <= r[0] + r[2] and r[1] <= cur[1] <= r[1] + r[3]: hovered = app
        menu_open = 110 <= i < 142
        plus_rect = rects_now[-1]
        plus_hovered = menu_open or (plus_rect[0] <= cur[0] <= plus_rect[0] + plus_rect[2] and plus_rect[1] <= cur[1] <= plus_rect[1] + plus_rect[3])
        img = scene(front, order)
        if previous and i - switched_at < 6:
            # A short crossfade from the window that was in front
            img = Image.blend(scene(previous, order), img, (i - switched_at + 1) / 6)
        draw_tabs(img, order, front, hovered, plus_hovered, badge='Mail')
        if menu_open:
            highlighted = 1 if i >= 124 else None
            draw_menu(img, menu, highlighted, alpha=min(255, (i - 110 + 1) * 64))
        cursor(img, cur, pressed=i in (20, 21, 62, 63, 108, 109, 140, 141))
        frames.append(img)
    return frames

# MARK: Menu bar panel

def panel_frames():
    MB = 26                         # menu bar
    M, G = 12, 10
    top = MB + M
    area_h = H - top - M
    rw = W - 2 * M
    left_w = (rw - G) * 0.5
    # Before: Dia left, Slack over Ghostty on the right
    before = {
        'Dia': (M, top, left_w, area_h),
        'Slack': (M + left_w + G, top, rw - left_w - G, (area_h - G) / 2),
        'Ghostty': (M + left_w + G, top + (area_h - G) / 2 + G, rw - left_w - G, (area_h - G) / 2),
    }
    # After dropping Ghostty left of Dia
    q = (left_w - G) / 2
    middle = {
        'Ghostty': (M, top, q, area_h),
        'Dia': (M + q + G, top, q, area_h),
        'Slack': (M + left_w + G, top, rw - left_w - G, area_h),
    }
    # After moving Slack to workspace 2
    end = {
        'Ghostty': (M, top, (rw - G) / 2, area_h),
        'Dia': (M + (rw - G) / 2 + G, top, (rw - G) / 2, area_h),
    }

    # The panel, under its menu bar icon
    PW = 330
    PX, PY = W - M - PW, MB + 6
    icon_x = W - 128
    map_x, map_y = PX + 14, PY + 52
    map_w = PW - 28
    scale = map_w / W
    map_h = (H - MB) * scale

    def to_map(rect):
        x, y, w, h = rect
        return (map_x + x * scale, map_y + (y - MB) * scale, w * scale, h * scale)

    def from_map(point):
        return ((point[0] - map_x) / scale, (point[1] - map_y) / scale + MB)

    chips = [(PX + 120 + i * 40, PY + 14, 34, 22) for i in range(3)]

    def menubar(img):
        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.rectangle([0, 0, W * S, MB * S], fill=(245, 245, 247, 200))
        d.text((18 * S, MB / 2 * S), '', font=font(14, 500), fill=(30, 30, 34, 255), anchor='lm')
        d.text((44 * S, MB / 2 * S), 'Finder', font=font(13, 700), fill=(30, 30, 34, 255), anchor='lm')
        # nanopress's icon: three tiles with space between them, the moving one filled
        x, y = icon_x * S, (MB / 2 - 7) * S
        d.rounded_rectangle([x, y, x + 8 * S, y + 14 * S], 2 * S, outline=(30, 30, 34, 255), width=int(1.5 * S))
        d.rounded_rectangle([x + 10 * S, y, x + 18 * S, y + 6 * S], 2 * S, outline=(30, 30, 34, 255), width=int(1.5 * S))
        d.rounded_rectangle([x + 10 * S, y + 8 * S, x + 18 * S, y + 14 * S], 2.5 * S, fill=(30, 30, 34, 255))
        d.text(((W - 70) * S, MB / 2 * S), '9:41', font=font(13, 500), fill=(30, 30, 34, 255), anchor='lm')
        img.paste(layer, (0, 0), layer)

    class Blend:
        """Draws each shape on its own layer and blends it in, so that see-through fills tint what's under them"""
        def __init__(self, size): self.image = Image.new('RGBA', size, (0, 0, 0, 0))
        def __getattr__(self, name):
            def draw(*args, **kwargs):
                top = Image.new('RGBA', self.image.size, (0, 0, 0, 0))
                getattr(ImageDraw.Draw(top), name)(*args, **kwargs)
                self.image = Image.alpha_composite(self.image, top)
            return draw
        def textlength(self, *args, **kwargs): return ImageDraw.Draw(self.image).textlength(*args, **kwargs)

    def panel(img, layout, alpha, drag=None, target_chip=None, chip_filled=False, landing=None):
        shadow(img, (PX, PY, PW, map_h + 66), radius=12, blur=20, alpha=int(120 * alpha / 255), offset=8)
        d = Blend(img.size)
        X, Y = PX * S, PY * S
        d.rounded_rectangle([X, Y, X + PW * S, Y + (map_h + 66) * S], 12 * S, fill=(242, 242, 245, 248), outline=(205, 205, 210, 255), width=S)
        d.text((X + 14 * S, Y + 25 * S), 'nanopress', font=font(13, 600), fill=(30, 30, 34, 255), anchor='lm')
        for i, chip in enumerate(chips):
            cx, cy, cw, ch = sc(chip)
            current = i == 0
            targeted = target_chip == i
            filled = i == 1 and chip_filled
            fill = ACCENT + (60,) if targeted else (0, 0, 0, 14) if (current or filled) else (0, 0, 0, 0)
            outline = ACCENT + (255,) if (current or targeted) else (0, 0, 0, 40 if filled else 70)
            d.rounded_rectangle([cx, cy, cx + cw, cy + ch], 5 * S, fill=fill, outline=outline, width=int((1.5 if current or targeted else 1) * S))
            color = ACCENT if (current or targeted) else (110, 110, 118) if filled else (160, 160, 168)
            d.text((cx + cw / 2, cy + ch / 2), str(i + 1), font=font(11, 600 if current else 500), fill=color + (255,), anchor='mm')
        # Toggle
        tx, ty = (PX + PW - 48) * S, (PY + 16) * S
        d.rounded_rectangle([tx, ty, tx + 32 * S, ty + 18 * S], 9 * S, fill=ACCENT + (255,))
        d.ellipse([tx + 15 * S, ty + 2 * S, tx + 29 * S, ty + 16 * S], fill=(255, 255, 255, 255))
        d.line([X, Y + 44 * S, X + PW * S, Y + 44 * S], fill=(215, 215, 220, 255), width=S)
        # The minimap
        mx, my = map_x * S, map_y * S
        d.rounded_rectangle([mx - 3 * S, my - 3 * S, mx + (map_w + 3) * S, my + (map_h + 3) * S], 8 * S, fill=(0, 0, 0, 12))
        for app, rect in layout.items():
            if drag and app == drag[0]:
                tile = to_map(rect)
                tx2, ty2, tw, th = sc(tile)
                d.rounded_rectangle([tx2 + S, ty2 + S, tx2 + tw - S, ty2 + th - S], 4 * S, outline=ACCENT + (120,), width=S)
                continue
            draw_tile(d, to_map(rect), app)
        if landing:
            lx, ly, lw, lh = sc(to_map(landing))
            d.rounded_rectangle([lx + S, ly + S, lx + lw - S, ly + lh - S], 4 * S, fill=ACCENT + (70,), outline=ACCENT + (255,), width=int(1.5 * S))
        layer = d.image
        if alpha < 255:
            layer.putalpha(layer.getchannel('A').point(lambda v: v * alpha // 255))
        img.paste(layer, (0, 0), layer)

    def draw_tile(d, tile, app, lifted=False):
        x, y, w, h = sc(tile)
        d.rounded_rectangle([x + S, y + S, x + w - S, y + h - S], 4 * S, fill=(220, 220, 226, 255) if not lifted else ACCENT + (60,),
                            outline=ACCENT + (255,) if lifted else None, width=int(1.5 * S))
        size = min(26 * S, w * 0.4, h * 0.4)
        color = APPS[app][0]
        d.rounded_rectangle([x + w / 2 - size / 2, y + h / 2 - size / 2, x + w / 2 + size / 2, y + h / 2 + size / 2], size * 0.25, fill=color + (255,))

    def lifted_tile(img, app, rect, center):
        d = Blend(img.size)
        # Small while dragged, so that it doesn't cover what it's dropped on
        w, h = min(to_map(rect)[2] * 0.8, 64), min(to_map(rect)[3] * 0.8, 44)
        draw_tile(d, (center[0] - w / 2, center[1] - h / 2, w, h), app, lifted=True)
        layer = d.image
        img.paste(layer, (0, 0), layer)

    def desktop(layout, preview=None):
        img = BG.copy()
        for app, rect in layout.items():
            window(img, rect, app)
        if preview:
            region(img, preview, fill_alpha=70)
        menubar(img)
        return img

    icon = (icon_x + 9, MB / 2)
    ghostty_map = to_map(before['Ghostty'])
    ghostty_grab = (ghostty_map[0] + ghostty_map[2] / 2, ghostty_map[1] + ghostty_map[3] / 2)
    dia_map = to_map(before['Dia'])
    drop_at = (dia_map[0] + 10, dia_map[1] + dia_map[3] / 2)
    slack_map = to_map(middle['Slack'])
    slack_grab = (slack_map[0] + slack_map[2] / 2, slack_map[1] + slack_map[3] / 2)
    chip2 = (chips[1][0] + chips[1][2] / 2, chips[1][1] + chips[1][3] / 2)
    keys = [
        (0, (520, 300)), (16, icon), (22, icon), (40, ghostty_grab), (46, ghostty_grab), (76, drop_at), (84, drop_at),
        (104, slack_grab), (110, slack_grab), (134, chip2), (142, chip2), (176, (520, 300)), (200, (520, 300)),
    ]
    def cursor_at(i):
        for (f1, p1), (f2, p2) in zip(keys, keys[1:]):
            if f1 <= i <= f2:
                t = ease_io((i - f1) / max(f2 - f1, 1))
                return (lerp(p1[0], p2[0], t), lerp(p1[1], p2[1], t))
        return keys[-1][1]

    def blend_layouts(a, b, t):
        out = {}
        for app in set(a) | set(b):
            if app in a and app in b: out[app] = lerp_rect(a[app], b[app], t)
            elif app in a: out[app] = a[app]
        return out

    frames = []
    for i in range(200):
        cur = cursor_at(i)
        panel_alpha = 0 if i < 22 else min(255, (i - 22 + 1) * 50) if i < 170 else max(0, 255 - (i - 170) * 50)
        drag = None
        landing = None
        target_chip = None
        preview = None
        if i < 84:
            layout = before
        elif i < 98:
            layout = blend_layouts(before, middle, ease((i - 84) / 14))
        elif i < 142:
            layout = middle
        elif i < 156:
            t = ease((i - 142) / 14)
            layout = blend_layouts({k: v for k, v in middle.items() if k != 'Slack'}, end, t)
        else:
            layout = end
        if 46 <= i < 84:
            drag = ('Ghostty', before['Ghostty'])
            if i >= 62:
                landing = middle['Ghostty']
                preview = middle['Ghostty']
        if 110 <= i < 142:
            drag = ('Slack', middle['Slack'])
            if i >= 128: target_chip = 1
        img = desktop(layout, preview)
        if panel_alpha > 0:
            panel(img, layout, panel_alpha, drag=drag, target_chip=target_chip, chip_filled=i >= 142, landing=landing)
            if drag:
                lifted_tile(img, drag[0], drag[1], cur)
        cursor(img, cur, pressed=i in (20, 21) or (46 <= i < 84) or (110 <= i < 142))
        frames.append(img)
    return frames

if __name__ == '__main__':
    which = sys.argv[2:] or ['drag', 'tabs', 'panel']
    if 'drag' in which: save(drag_frames(), 'drag-and-drop.gif')
    if 'tabs' in which: save(tabs_frames(), 'stack-tabs.gif')
    if 'panel' in which: save(panel_frames(), 'menu-bar-panel.gif')
