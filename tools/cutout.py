import sys, numpy as np
from PIL import Image
from scipy import ndimage as nd
src, out = sys.argv[1], sys.argv[2]
im = np.array(Image.open(src).convert('RGB')).astype(np.float32)
H, W, _ = im.shape
mn, mx = im.min(2), im.max(2)
whiteish = (mn >= 244) & (mx - mn <= 8)
lab, n = nd.label(whiteish)
border = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
bg = np.isin(lab, list(border))
# enclosed pure-white pockets (gaps between hair and arms) — large and very white only
# enclosed gaps between hair and arms: flat paper white (spread < 2); socks are warmer
wh2 = (mn >= 240) & (mx - mn <= 10)
lab2, n2 = nd.label(wh2)
for i, sl in enumerate(nd.find_objects(lab2), 1):
    comp = lab2[sl] == i
    if comp.sum() < 150: continue
    sub = im[sl][comp]
    if sub.min(1).mean() >= 248 and (sub.max(1) - sub.min(1)).mean() < 2:
        bg[sl] |= comp
fg = ~bg
alpha = fg.astype(np.float32)
# soft edge: background pixels touching foreground get alpha from darkness
band = bg & nd.binary_dilation(fg, iterations=2)
ref = nd.minimum_filter(mn, size=5)  # darkest nearby ink = what the edge pixel was mixed from
a = np.clip((255 - mn) / np.maximum(255 - ref, 40), 0, 1)
alpha[band] = a[band]
# fg pixels on the edge that are near-white also soften
edge_fg = fg & nd.binary_dilation(bg, iterations=2)
alpha[edge_fg] = a[edge_fg]
# decontaminate colour from white
safe = np.maximum(alpha, 1e-3)[..., None]
col = np.clip((im - (1 - alpha[..., None]) * 255) / safe, 0, 255)
col = np.where(alpha[..., None] > 0.98, im, col)
rgba = np.dstack([col, alpha * 255]).astype(np.uint8)
Image.fromarray(rgba).save(out)
print('saved', out, 'enclosed pockets checked', n)
