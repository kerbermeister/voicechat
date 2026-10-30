(() => {
  'use strict';
  globalThis.voicechatPhotos = Object.freeze({
    async normalize(bytes, mime, maxPixels, scale, quality, maxBytes) {
      if (!(bytes instanceof Uint8Array) || bytes.length === 0 || bytes.length > 64 * 1024 * 1024) throw new Error('Invalid source size');
      const url = URL.createObjectURL(new Blob([bytes], {type: mime}));
      const image = new Image();
      let timeout;
      try {
        image.src = url;
        await Promise.race([image.decode(), new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('Photo decode timeout')), 20000); })]);
        const w = image.naturalWidth, h = image.naturalHeight;
        if (w <= 0 || h <= 0 || w * h > 64000000) throw new Error('Source exceeds 64 MP');
        const ratio = Math.min(scale, Math.sqrt(maxPixels / (w * h)));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(w * ratio));
        canvas.height = Math.max(1, Math.round(h * ratio));
        try {
          const context = canvas.getContext('2d', {alpha: false});
          if (!context) throw new Error('Canvas unavailable');
          context.fillStyle = '#fff'; context.fillRect(0, 0, canvas.width, canvas.height);
          context.drawImage(image, 0, 0, canvas.width, canvas.height);
          const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', quality / 100));
          if (!blob || blob.size > maxBytes || blob.type !== 'image/jpeg') throw new Error('Photo output exceeds limit');
          return {bytes: new Uint8Array(await blob.arrayBuffer()), width: canvas.width, height: canvas.height};
        } finally { canvas.width = 0; canvas.height = 0; }
      } finally {
        clearTimeout(timeout); image.src = ''; URL.revokeObjectURL(url);
      }
    },
  });
})();
