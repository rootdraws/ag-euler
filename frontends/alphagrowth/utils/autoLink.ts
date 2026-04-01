const URL_RE = /https?:\/\/[^\s<>"')\]]+/g

const escapeHtml = (text: string): string =>
  text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')

export const autoLink = (text: string): string => {
  const escaped = escapeHtml(text)
  return escaped.replace(URL_RE, url =>
    `<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`,
  )
}
