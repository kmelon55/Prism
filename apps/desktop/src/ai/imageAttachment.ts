import type { ChatImage } from "../providers/aiHistory";

const MAX_FILE_BYTES = 40 * 1024 * 1024;
const MAX_IMAGE_URL = 1_400_000;

/** Read only the explicitly dropped file; never fetch URLs or arbitrary local paths. */
export async function prepareImageAttachment(file: File): Promise<ChatImage> {
  if (!/^image\/(png|jpeg|webp)$/.test(file.type)) throw "Choose a PNG, JPEG, or WebP image.";
  if (!file.size || file.size > MAX_FILE_BYTES) throw "Choose an image smaller than 40 MB.";
  const dataUrl = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject("Could not read this image.");
    reader.readAsDataURL(file);
  });
  const source = new Image();
  try {
    await new Promise<void>((resolve, reject) => {
      source.onload = () => resolve();
      source.onerror = () => reject("Could not read this image.");
      source.src = dataUrl;
    });
    if (!source.naturalWidth || !source.naturalHeight || source.naturalWidth > 20000 || source.naturalHeight > 20000
      || source.naturalWidth * source.naturalHeight > 64_000_000) throw "This image is too large. Choose a smaller image.";
    const scale = Math.min(1, 1600 / Math.max(source.naturalWidth, source.naturalHeight));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(source.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(source.naturalHeight * scale));
    const context = canvas.getContext("2d");
    if (!context) throw "Could not read this image.";
    // JPEG has no alpha channel: flatten transparent screenshots onto white.
    context.fillStyle = "#fff";
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(source, 0, 0, canvas.width, canvas.height);
    for (const quality of [0.85, 0.7, 0.55, 0.4]) {
      const encoded = canvas.toDataURL("image/jpeg", quality);
      if (encoded.startsWith("data:image/jpeg;base64,") && encoded.length <= MAX_IMAGE_URL) return { dataUrl: encoded };
    }
    throw "This image is too large. Choose a smaller image.";
  } finally {
    source.onload = null;
    source.onerror = null;
    source.src = "";
  }
}
