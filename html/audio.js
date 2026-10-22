'use strict';
// FiveM audio + right-center belt reminder icon; no NUI focus or input capture.
const sounds = Object.freeze({
  buckle: new Audio('sounds/buckle.wav'),
  unbuckle: new Audio('sounds/unbuckle.wav'),
  reminder: new Audio('sounds/reminder.wav')
});

for (const audio of Object.values(sounds)) {
  audio.preload = 'auto';
}

const clampVolume = (value) => {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(1, Math.max(0, number)) : 0.5;
};

const stopSound = (audio) => {
  audio.pause();
  try { audio.currentTime = 0; } catch (_) { /* Not loaded yet. */ }
};

window.addEventListener('message', ({ data }) => {
  if (!data || typeof data !== 'object') return;

  if (data.action === 'beltIndicator') {
    document.body.classList.toggle('show-belt-warning', data.show === true);
    return;
  }

  if (data.action === 'stopReminder') {
    stopSound(sounds.reminder);
    return;
  }

  if (data.action === 'stopAll') {
    document.body.classList.remove('show-belt-warning');
    for (const audio of Object.values(sounds)) stopSound(audio);
    return;
  }

  if (data.action !== 'play' || typeof data.sound !== 'string') return;
  const audio = Object.hasOwn(sounds, data.sound) ? sounds[data.sound] : null;
  if (!audio) return;
  stopSound(audio);
  audio.volume = clampVolume(data.volume);
  const started = audio.play();
  if (started && typeof started.catch === 'function') {
    started.catch((error) => console.warn('[rs-seatbelt] NUI audio playback failed:', error));
  }
});
