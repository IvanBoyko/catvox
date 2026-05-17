function isPlaceholder(value) {
  const lower = String(value).toLowerCase();
  return (
    value.includes('$(') ||
    value.includes('<') ||
    value.includes('>') ||
    lower.includes('replace-with') ||
    lower.includes('placeholder') ||
    lower === 'todo'
  );
}

module.exports = {
  isPlaceholder,
};
