import sys
from PIL import Image, ImageSequence


def to_rgb565(r, g, b):
    val = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
    # TFT_eSPI's pushImage() sends bytes MSB-first without swapping by default;
    # setSwapBytes(true) crashes on this board, so pre-swap the byte order here
    # instead so pushImage's default (no-swap) path already gets the right bytes.
    return ((val & 0xFF) << 8) | (val >> 8)


def load_gif_frames(gif_path):
    with Image.open(gif_path) as im:
        return [frame.convert("RGBA").copy() for frame in ImageSequence.Iterator(im)]


def rgb_pixels(frame):
    """Iterate RGB pixels without Pillow's deprecated getdata() API."""
    data = frame.tobytes()
    return zip(data[0::3], data[1::3], data[2::3])


def slice_spritesheet_row(sheet_img, cell_w, cell_h, row=0, max_cols=None):
    cols = sheet_img.width // cell_w
    if max_cols:
        cols = min(cols, max_cols)
    frames = []
    for col in range(cols):
        box = (col * cell_w, row * cell_h, (col + 1) * cell_w, (row + 1) * cell_h)
        cell = sheet_img.crop(box).convert("RGBA")
        if cell.getbbox() is None:
            continue  # fully transparent/empty cell, past the real frame count
        frames.append(cell)
    return frames


def process_frames(frames, out_w, out_h, max_frames=None):
    """Flatten transparency onto black, resize, and optionally subsample down
    to at most max_frames evenly-spaced frames. Returns a list of RGB PIL images."""
    processed = []
    for rgba in frames:
        bg = Image.new("RGBA", rgba.size, (0, 0, 0, 255))
        bg.alpha_composite(rgba)
        rgb = bg.convert("RGB").resize((out_w, out_h), Image.LANCZOS)
        processed.append(rgb)

    if max_frames and len(processed) > max_frames:
        step = len(processed) / max_frames
        indices = [int(i * step) for i in range(max_frames)]
        processed = [processed[i] for i in indices]
    return processed


def frame_to_raw_bytes(frame):
    """Raw RGB565 bytes for one frame, in the exact byte order the firmware's
    pushImage() expects (see to_rgb565's note on the swap)."""
    out = bytearray()
    for r, g, b in rgb_pixels(frame):
        val = to_rgb565(r, g, b)
        out.append(val & 0xFF)
        out.append(val >> 8)
    return bytes(out)


def frames_to_payload(frames, out_w, out_h, max_frames=None):
    """Wire format for POSTing to the device: [1 byte frame count][frame0][frame1]...
    Each frame is out_w*out_h*2 raw bytes. Matches what the firmware's
    /sprite/<target> endpoint parses."""
    processed = process_frames(frames, out_w, out_h, max_frames)
    payload = bytes([len(processed)])
    for fr in processed:
        payload += frame_to_raw_bytes(fr)
    return payload


def frames_to_header(frames, out_w, out_h, var_name, header_path, max_frames=None):
    processed = process_frames(frames, out_w, out_h, max_frames)

    with open(header_path, "w") as f:
        f.write("#pragma once\n#include <Arduino.h>\n\n")
        f.write(f"#define {var_name.upper()}_W {out_w}\n")
        f.write(f"#define {var_name.upper()}_H {out_h}\n")
        f.write(f"#define {var_name.upper()}_FRAMES {len(processed)}\n\n")
        for i, fr in enumerate(processed):
            f.write(f"const uint16_t {var_name}_{i}[{out_w * out_h}] PROGMEM = {{\n")
            vals = [str(to_rgb565(r, g, b)) for r, g, b in rgb_pixels(fr)]
            for row_start in range(0, len(vals), 16):
                f.write(",".join(vals[row_start:row_start + 16]) + ",\n")
            f.write("};\n\n")
        f.write(f"const uint16_t* const {var_name}_frames[{var_name.upper()}_FRAMES] = {{\n")
        f.write(",".join(f"{var_name}_{i}" for i in range(len(processed))))
        f.write("\n};\n")
    print(f"wrote {header_path}: {len(processed)} frames at {out_w}x{out_h}")


def convert(gif_path, out_w, out_h, var_name, header_path, max_frames=None):
    frames_to_header(load_gif_frames(gif_path), out_w, out_h, var_name, header_path, max_frames)


if __name__ == "__main__":
    max_frames = int(sys.argv[6]) if len(sys.argv) > 6 else None
    convert(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5], max_frames)
