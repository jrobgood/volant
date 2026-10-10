// oxlint-disable next/no-html-link-for-pages -- vinext 1.0.0-beta.5's next/link throws in the
// production build (RSC prefetch setup and the click handler both fail), leaving internal
// navigation dead. Plain anchors until that is fixed upstream. See QUALITY.md.
import Image from 'next/image';

export const repositoryURL = 'https://github.com/mysticcoders/volant';
export const socialURL = 'https://x.com/mysticcoders';
export const appVersion = '0.2.4';
export const downloadURL = `/updates/Volant-${appVersion}.dmg`;

export function Brand() {
  return (
    <span className="brand">
      <Image unoptimized src="/favicon.svg" alt="" width="30" height="30" />
      volant<span className="brand-dot">.</span>
    </span>
  );
}

export function SiteHeader() {
  return (
    <header id="top" className="nav wrap">
      <a href="/" aria-label="Volant home">
        <Brand />
      </a>
      <nav aria-label="Main navigation">
        <a href="/#answers">Answers</a>
        <a href="/#agents">Agents</a>
        <a href="/#launcher">Launcher</a>
        <a href="/#notes">Notes</a>
        <a href="/docs">Docs</a>
      </nav>
      <div className="nav-actions">
        <a
          href={repositoryURL}
          className="nav-github"
          aria-label="Volant on GitHub"
        />
        <a className="button small" href={downloadURL} download>
          Download
        </a>
      </div>
    </header>
  );
}

export function SiteFooter() {
  return (
    <footer className="wrap">
      <a href="/" aria-label="Volant home">
        <Brand />
      </a>
      <span>
        Made by <a href="https://mysticcoders.com">Mystic Coders</a>.
      </span>
      <div className="social-links">
        <a href={repositoryURL} aria-label="Volant on GitHub">
          <Image
            unoptimized
            src="/icons/github.svg"
            alt=""
            width={20}
            height={20}
            className="social-icon"
          />{' '}
          GitHub
        </a>
        <a href={socialURL} aria-label="Mystic Coders on X (Twitter)">
          <Image
            unoptimized
            src="/icons/x.svg"
            alt=""
            width={18}
            height={18}
            className="social-icon"
          />{' '}
          @mysticcoders
        </a>
        <a href={`${repositoryURL}/blob/main/LICENSE`}>MIT license</a>
      </div>
    </footer>
  );
}
