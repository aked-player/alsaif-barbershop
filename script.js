const menuToggle = document.querySelector(".menu-toggle");
const nav = document.querySelector(".site-nav");

if (menuToggle && nav) {
  menuToggle.addEventListener("click", () => {
    nav.classList.toggle("open");
  });

  nav.querySelectorAll("a").forEach((link) => {
    link.addEventListener("click", () => nav.classList.remove("open"));
  });
}

const logo = document.querySelector("#shop-logo");
const logoContainer = document.querySelector(".hero-logo-wrap");

if (logo && logoContainer) {
  const showFallback = () => logoContainer.classList.add("logo-missing");

  if (logo.complete && logo.naturalWidth === 0) {
    showFallback();
  }

  logo.addEventListener("error", showFallback);
}

const revealItems = document.querySelectorAll(".reveal");

if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("visible");
          observer.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.14 }
  );

  revealItems.forEach((item, i) => {
    item.style.transitionDelay = `${i * 0.08}s`;
    observer.observe(item);
  });
} else {
  revealItems.forEach((item) => item.classList.add("visible"));
}
