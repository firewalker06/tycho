/* One record owns both the illustration and its caption. No animated transitions. */
window.TychoNowFred = (() => {
  const variants = Object.freeze([
    Object.freeze({ id: "d", image: "/now-fred/d.webp", text: "All done. Hooray!" }),
    Object.freeze({ id: "e", image: "/now-fred/e.webp", text: "Nothing left? Thought so." }),
    Object.freeze({ id: "f", image: "/now-fred/f.webp", text: "And… relax. All done." }),
  ]);

  function create({ random = Math.random, setTimer = window.setTimeout.bind(window), clearTimer = window.clearTimeout.bind(window), changed }) {
    let selected = null;
    let previous = null;
    let timer = null;
    let active = false;
    let visible = false;
    let reducedMotion = false;
    const stop = () => {
      if (timer !== null) clearTimer(timer);
      timer = null;
    };
    const choose = () => {
      const choices = variants.filter(variant => variant !== previous);
      selected = choices[Math.min(choices.length - 1, Math.floor(random() * choices.length))];
      previous = selected;
    };
    const schedule = () => {
      if (!active || !visible || reducedMotion || timer !== null) return;
      timer = setTimer(() => {
        timer = null;
        choose();
        changed();
        schedule();
      }, 30000);
    };
    return {
      update({ empty, shown, reduce = false }) {
        active = empty;
        visible = shown;
        reducedMotion = reduce;
        if (!active) selected = null;
        else if (!selected) choose();
        if (!active || !visible || reducedMotion) stop();
        else schedule();
        return selected;
      },
      dispose() {
        active = false;
        selected = null;
        stop();
      },
    };
  }
  return Object.freeze({ variants, create });
})();
