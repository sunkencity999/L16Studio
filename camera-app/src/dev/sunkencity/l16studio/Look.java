package dev.sunkencity.l16studio;

import android.graphics.Bitmap;
import android.renderscript.Allocation;
import android.renderscript.Element;
import android.renderscript.Matrix3f;
import android.renderscript.RenderScript;
import android.renderscript.ScriptIntrinsicColorMatrix;
import android.renderscript.ScriptIntrinsicConvolve3x3;
import android.renderscript.ScriptIntrinsicLUT;

/**
 * An edit: everything needed to turn the camera's preview into a finished
 * picture. It has two layers.
 *
 * The first is measured from the photo itself ({@link #analyse}): where its
 * darkest and brightest tones sit, how bright its mid-tones are, and whether
 * it has a colour cast. Correcting those is what "Auto" means.
 *
 * The second is taste: contrast, shadow and highlight shaping, saturation,
 * warmth, fade, sharpening. A {@link Style} is a preset of these, and the
 * sliders in the editor change them one at a time.
 *
 * Rendering is three GPU-friendly passes (RenderScript intrinsics): a
 * per-channel tone curve, a saturation matrix, and a sharpening kernel.
 */
final class Look {
    // ---- measured from the photo (identity until analysed) --------------
    float black = 0f;          // input level mapped to black, 0..1
    float white = 1f;          // input level mapped to white, 0..1
    float gamma = 1f;          // mid-tone correction (<1 brightens)
    float gainR = 1f, gainG = 1f, gainB = 1f; // colour-cast correction
    /** How much of the measured correction to apply, 0..1. */
    float auto = 1f;

    // ---- taste (all 0 = neutral unless noted) ---------------------------
    float exposure;            // EV, -2..2
    float contrast;            // -1..1
    float highlights;          // -1..1, positive pulls bright tones down
    float shadows;             // -1..1, positive lifts dark tones
    float saturation = 1f;     // 0 = monochrome, 1 = unchanged
    float warmth;              // -1..1, positive is warmer
    float fade;                // 0..1, lifts black for a matte look
    float split;               // 0..1, cool shadows and warm highlights
    float sharpen;             // 0..1

    Look copy() {
        Look c = new Look();
        c.black = black; c.white = white; c.gamma = gamma;
        c.gainR = gainR; c.gainG = gainG; c.gainB = gainB; c.auto = auto;
        c.exposure = exposure; c.contrast = contrast; c.highlights = highlights; c.shadows = shadows;
        c.saturation = saturation; c.warmth = warmth; c.fade = fade; c.split = split; c.sharpen = sharpen;
        return c;
    }

    /** The named looks offered in the editor. */
    enum Style {
        ORIGINAL("Original"),
        AUTO("Auto"),
        VIVID("Vivid"),
        GOLDEN("Golden"),
        CRISP("Crisp"),
        FILM("Film"),
        MONO("Mono");

        final String label;
        Style(String label) { this.label = label; }
    }

    /**
     * Builds a look for `style` on top of the photo's own measurements.
     * Every style except Original starts from the Auto correction, so the
     * styles differ in character, not in whether the exposure is right.
     */
    static Look forStyle(Style style, Look measured) {
        Look look = measured.copy();
        switch (style) {
            case ORIGINAL:
                return new Look();
            case AUTO:
                look.contrast = 0.12f; look.saturation = 1.08f; look.shadows = 0.10f; look.sharpen = 0.35f;
                break;
            case VIVID:
                look.contrast = 0.40f; look.saturation = 1.38f; look.shadows = 0.18f; look.highlights = 0.10f; look.sharpen = 0.50f;
                break;
            case GOLDEN:
                look.warmth = 0.55f; look.shadows = 0.28f; look.highlights = 0.22f; look.contrast = 0.10f;
                look.saturation = 1.12f; look.sharpen = 0.35f;
                break;
            case CRISP:
                look.warmth = -0.30f; look.contrast = 0.32f; look.highlights = 0.30f; look.shadows = 0.05f;
                look.saturation = 1.04f; look.sharpen = 0.85f;
                break;
            case FILM:
                look.fade = 0.75f; look.split = 0.8f; look.contrast = -0.05f; look.saturation = 0.86f;
                look.warmth = 0.12f; look.highlights = 0.20f; look.sharpen = 0.20f;
                break;
            case MONO:
                look.saturation = 0f; look.contrast = 0.42f; look.shadows = -0.05f; look.highlights = 0.12f; look.sharpen = 0.45f;
                break;
        }
        return look;
    }

    /**
     * Measures a photo. `sample` should be a small copy (a few hundred pixels
     * wide); the statistics don't need more.
     */
    static Look analyse(Bitmap sample) {
        int w = sample.getWidth(), h = sample.getHeight();
        int[] pixels = new int[w * h];
        sample.getPixels(pixels, 0, w, 0, 0, w, h);

        int[] histogram = new int[256];
        double sumR = 0, sumG = 0, sumB = 0;
        long counted = 0;
        for (int p : pixels) {
            int r = (p >> 16) & 0xff, g = (p >> 8) & 0xff, b = p & 0xff;
            int luma = (r * 54 + g * 183 + b * 19) >> 8;
            histogram[luma]++;
            // Colour cast: average only reasonably neutral mid-tones. Strongly
            // coloured or clipped pixels say nothing about the light.
            int max = Math.max(r, Math.max(g, b)), min = Math.min(r, Math.min(g, b));
            if (luma > 40 && luma < 225 && max - min < 60) {
                sumR += r; sumG += g; sumB += b; counted++;
            }
        }

        Look look = new Look();
        int total = pixels.length;
        // Black and white points: the 0.4th and 99.6th percentiles, so a few
        // stray pixels don't decide the range. Limited, so a deliberately
        // dark or light picture isn't forced to full range.
        int lo = percentile(histogram, total, 0.004), hi = percentile(histogram, total, 0.996);
        look.black = Math.min(0.14f, lo / 255f);
        look.white = Math.max(0.80f, hi / 255f);

        // Mid-tones: bring the median towards a pleasing level, gently.
        int median = percentile(histogram, total, 0.5);
        float range = Math.max(0.2f, look.white - look.black);
        float mid = Math.min(0.95f, Math.max(0.05f, (median / 255f - look.black) / range));
        float target = 0.46f;
        float exact = (float) (Math.log(target) / Math.log(mid));
        look.gamma = Math.min(1.35f, Math.max(0.65f, 1 + (exact - 1) * 0.6f));

        // Colour cast: nudge the neutral average towards grey, at most 12%
        // per channel and only if enough of the picture was neutral.
        if (counted > total / 20) {
            double r = sumR / counted, g = sumG / counted, b = sumB / counted;
            double grey = (r + g + b) / 3;
            look.gainR = limit((float) (grey / r), 0.6f);
            look.gainG = limit((float) (grey / g), 0.6f);
            look.gainB = limit((float) (grey / b), 0.6f);
        }
        return look;
    }

    private static float limit(float gain, float strength) {
        float g = 1 + (gain - 1) * strength;
        return Math.min(1.12f, Math.max(0.88f, g));
    }

    private static int percentile(int[] histogram, int total, double fraction) {
        long target = (long) (total * fraction), seen = 0;
        for (int i = 0; i < 256; i++) {
            seen += histogram[i];
            if (seen >= target) return i;
        }
        return 255;
    }

    // ---- rendering ------------------------------------------------------

    /** Builds the tone curve for one channel (0 = red, 1 = green, 2 = blue). */
    private byte[] curve(int channel) {
        float gain = channel == 0 ? gainR : channel == 1 ? gainG : gainB;
        gain = 1 + (gain - 1) * auto;
        // Warmth trades red against blue; green stays put.
        if (channel == 0) gain *= 1 + 0.14f * warmth;
        if (channel == 2) gain *= 1 - 0.14f * warmth;
        float lo = black * auto, hi = 1 - (1 - white) * auto;
        float g = 1 + (gamma - 1) * auto;
        float exposureGain = (float) Math.pow(2, exposure);

        byte[] table = new byte[256];
        for (int i = 0; i < 256; i++) {
            float x = i / 255f;
            x = (x - lo) / (hi - lo);
            x = Math.max(0, Math.min(1, x * gain * exposureGain));
            x = (float) Math.pow(x, g);

            // Shadows and highlights: smooth bumps centred a third and two
            // thirds of the way up, so each leaves the other end alone.
            float shadowBump = x * (1 - x) * (1 - x) * 6.75f;
            float highlightBump = x * x * (1 - x) * 6.75f;
            x += 0.20f * shadows * shadowBump - 0.20f * highlights * highlightBump;

            // Contrast: blend towards an S-curve, or towards flat grey.
            if (contrast >= 0) {
                float s = x * x * (3 - 2 * x);
                x = x + (s - x) * contrast;
            } else {
                x = x + (0.5f - x) * (-contrast * 0.45f);
            }

            // Split toning: shadows lean cool, highlights lean warm.
            if (split != 0 && channel != 1) {
                float lean = (x - 0.5f) * 0.09f * split;
                x += channel == 0 ? lean : -lean;
            }

            // Fade: lift the black point for a matte finish.
            x = fade * 0.11f + x * (1 - fade * 0.11f);

            table[i] = (byte) Math.round(Math.max(0, Math.min(1, x)) * 255);
        }
        return table;
    }

    /**
     * Renders `source` (ARGB_8888) into a new bitmap, using the caller's
     * RenderScript context (creating one per render is slow). `sharpenScale` shrinks
     * the sharpening for reduced-size previews, where the same kernel would
     * look much stronger than it will at full size.
     */
    Bitmap render(RenderScript rs, Bitmap source, float sharpenScale) {
        {
            Allocation a = Allocation.createFromBitmap(rs, source);
            Allocation b = Allocation.createTyped(rs, a.getType());

            ScriptIntrinsicLUT lut = ScriptIntrinsicLUT.create(rs, Element.U8_4(rs));
            byte[] red = curve(0), green = curve(1), blue = curve(2);
            for (int i = 0; i < 256; i++) {
                lut.setRed(i, red[i] & 0xff);
                lut.setGreen(i, green[i] & 0xff);
                lut.setBlue(i, blue[i] & 0xff);
                lut.setAlpha(i, i);
            }
            lut.forEach(a, b);

            // Saturation about luma (Rec. 709 weights).
            float s = saturation, lr = 0.2126f * (1 - s), lg = 0.7152f * (1 - s), lb = 0.0722f * (1 - s);
            Matrix3f m = new Matrix3f(new float[] {
                    lr + s, lr, lr,
                    lg, lg + s, lg,
                    lb, lb, lb + s });
            ScriptIntrinsicColorMatrix colour = ScriptIntrinsicColorMatrix.create(rs, Element.U8_4(rs));
            colour.setColorMatrix(m);
            colour.forEach(b, a);

            Allocation result = a;
            float amount = sharpen * 0.55f * sharpenScale;
            if (amount > 0.01f) {
                ScriptIntrinsicConvolve3x3 kernel = ScriptIntrinsicConvolve3x3.create(rs, Element.U8_4(rs));
                kernel.setCoefficients(new float[] {
                        0, -amount, 0,
                        -amount, 1 + 4 * amount, -amount,
                        0, -amount, 0 });
                kernel.setInput(a);
                kernel.forEach(b);
                result = b;
            }

            Bitmap out = Bitmap.createBitmap(source.getWidth(), source.getHeight(), Bitmap.Config.ARGB_8888);
            result.copyTo(out);
            a.destroy();
            b.destroy();
            return out;
        }
    }
}
