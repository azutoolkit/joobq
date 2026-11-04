/** Escapes HTML and turns `backtick` spans in data strings into <code> elements. */
export function inlineCode(text: string): string {
  const escaped = text.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
  return escaped.replace(/`([^`]+)`/g, '<code>$1</code>');
}
