# OCR search

Find a screenshot, a photo of a document or a scanned PDF by what is written in it: a bank transfer receipt by its amount, a contract by a clause, a slide by its title.

**Open it** with the **OCR** pill in the filter bar (always shown, last), `Cmd+4`, the fourth round button next to the empty search bar, or `Tab` until it is selected. The search bar shows an `OCR` chip; type 3 or more characters. Each result shows the line the words were found in, with a preview of the file on the right. `Esc`, the **All** pill or `Tab` go back to the normal name search.

**What is read**

| File | How |
| --- | --- |
| Images: png, jpg, jpeg, heic, heif, tiff, gif, bmp, webp | OCR |
| PDFs with a text layer | The text layer, plus OCR of pictures on the page (screenshots, photos) |
| Scanned PDFs | OCR, page by page |

Text files (.md, .txt, .docx, …) are not part of OCR search; find them by name as usual.

**Matching.** Case and accents are ignored, so `hoa don` finds "Hóa Đơn". Every word of 3+ characters must appear in the file, anywhere and in any order; shorter words are skipped.

**Indexing.** Lumio reads the folders it already indexes (`file_scan_roots`, `file_scan_extra_roots`, default Desktop, Documents and Downloads, minus `file_exclude_paths` and `skip_dir_names`), newest files first. It starts about 20 seconds after launch, then picks up new or changed files at most every 15 minutes when you open Lumio; unchanged files are never read twice. While it runs, the OCR tab shows how many files have text and how many are left, and refreshes by itself. Expect about a minute before the first file after each launch (macOS loads its text-recognition model), then a fraction of a second per image.

**Privacy.** Text recognition runs on your Mac with Apple's Vision framework; nothing is uploaded. The recognized text is stored in `~/Library/Application Support/lumio/content-index.db`.

**Limits.** At most `content_index_limit` files (3000 by default), the newest ones. Images over 40 MB and PDFs over 200 MB are skipped; per PDF, up to 300 pages are read and up to 15 of them OCR'd; up to 30,000 characters are kept per file. Images smaller than 48 px (icons) are skipped.

| Config key | Default | Does |
| --- | --- | --- |
| `content_index_enabled` | `true` | `false` turns OCR search off and deletes the stored text |
| `content_index_limit` | `3000` | Most files read (100–20000), newest first |
