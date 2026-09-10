import { File, FileArchive, FileAudio, FileCode2, FileImage, FileSpreadsheet, FileText, FileVideo, FolderOpen, Presentation } from "lucide-react";

export const fileIcons = {
  file: File,
  "folder-open": FolderOpen,
  "file-text": FileText,
  "file-image": FileImage,
  "file-code": FileCode2,
  "file-archive": FileArchive,
  "file-audio": FileAudio,
  "file-video": FileVideo,
  "file-spreadsheet": FileSpreadsheet,
  "file-presentation": Presentation,
};

const extensionGroups: Array<[keyof typeof fileIcons, string]> = [
  ["file-text", "pdf txt md mdx rtf doc docx odt pages hwp hwpx epub"],
  ["file-image", "png jpg jpeg gif webp svg heic heif avif bmp tiff tif ico psd ai sketch fig"],
  ["file-code", "js jsx ts tsx mjs cjs json jsonc html htm css scss less py rs go java kt kts swift c h cpp hpp cs rb php sh bash zsh fish sql yaml yml toml xml vue svelte"],
  ["file-archive", "zip rar 7z tar gz bz2 xz tgz zst dmg iso"],
  ["file-audio", "mp3 m4a wav flac aac ogg aiff opus"],
  ["file-video", "mp4 mov m4v mkv avi webm mpeg mpg"],
  ["file-spreadsheet", "csv tsv xls xlsx ods numbers"],
  ["file-presentation", "ppt pptx odp key"],
];
const extensions = new Map(extensionGroups.flatMap(([icon, group]) =>
  group.split(" ").map((extension) => [extension, icon] as const),
));

export function fileIconName(name: string, isDirectory: boolean): keyof typeof fileIcons {
  if (isDirectory) return "folder-open";
  const dot = name.lastIndexOf(".");
  return dot > 0 ? extensions.get(name.slice(dot + 1).toLowerCase()) ?? "file" : "file";
}
