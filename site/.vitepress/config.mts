import { defineConfig } from 'vitepress'
import { posix } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readFileSync } from 'node:fs'

// Pages live outside this package, so resolve their imports from site/node_modules.
const modules = fileURLToPath(new URL('../node_modules/', import.meta.url))

const repo = 'https://github.com/LouLouLibs/vm-launcher'

// Served under /vm-launcher/ by default (scripts/docs-site.sh serve);
// VMLAUNCHER_DOCS_BASE overrides it, e.g. '/' for a dedicated host.
const base = process.env.VMLAUNCHER_DOCS_BASE || '/vm-launcher/'

// One version for the package and the site: the vm-launcher derivation in
// flake.nix (anchored on its pname; the file pins other versions too).
const version = readFileSync(new URL('../../flake.nix', import.meta.url), 'utf8').match(/pname = "vm-launcher";\s*version = "([^"]+)"/)![1]

// Links from a page to repository files outside docs/ (the contract, lib/,
// the README) point at GitHub instead of a missing page.
function repoLinks(md: any) {
  const render = md.renderer.rules.link_open ?? ((t: any, i: number, o: any, _e: any, s: any) => s.renderToken(t, i, o))
  md.renderer.rules.link_open = (tokens: any, idx: number, options: any, env: any, self: any) => {
    const href: string = tokens[idx].attrGet('href') ?? ''
    if (href && !/^[a-z]+:|^#|^\//i.test(href) && env?.relativePath) {
      const target = posix.normalize(posix.join('docs', posix.dirname(env.relativePath), href))
      if (!target.startsWith('docs/')) tokens[idx].attrSet('href', `${repo}/blob/main/${target}`)
    }
    return render(tokens, idx, options, env, self)
  }
}

// The pages live in ../docs so they stay readable on GitHub.
export default defineConfig({
  title: 'vm-launcher',
  description: 'vm-launcher runs coding agents inside a per-session NixOS microVM with a policy-defined egress fence.',
  lang: 'en-US',
  base,
  srcDir: '../docs',
  srcExclude: ['usage.md'],
  // Plain static file servers don't map /page to page.html, so keep .html links.
  cleanUrls: false,
  lastUpdated: true,
  markdown: { config: repoLinks },
  vite: { resolve: { alias: [{ find: /^vue(\/.*)?$/, replacement: `${modules}vue$1` }] } },
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: `${base}logo.svg` }],
  ],
  themeConfig: {
    version,
    logo: '/logo.svg',
    nav: [
      { text: 'Guide', link: '/getting-started', activeMatch: '^/(getting-started|running|policies|network|credentials|connectors|inside-the-vm|troubleshooting)' },
      { text: 'Reference', link: '/cli', activeMatch: '^/(cli|contract)' },
      { text: 'Development', link: '/dev/architecture', activeMatch: '^/dev/' },
      { text: `v${version}`, items: [{ text: 'Source on GitHub', link: repo }] },
    ],
    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting started', link: '/getting-started' },
          { text: 'Running VMs', link: '/running' },
          { text: 'Writing a policy', link: '/policies' },
          { text: 'Network and egress', link: '/network' },
          { text: 'Credentials and logins', link: '/credentials' },
          { text: 'claude.ai connectors', link: '/connectors' },
          { text: 'Inside the VM', link: '/inside-the-vm' },
          { text: 'Troubleshooting', link: '/troubleshooting' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'Command line', link: '/cli' },
          { text: 'Policy contract', link: '/contract' },
        ],
      },
      {
        text: 'Development',
        collapsed: true,
        items: [
          { text: 'Architecture', link: '/dev/architecture' },
          { text: 'Testing', link: '/dev/testing' },
        ],
      },
    ],
    outline: { level: [2, 3], label: 'Contents' },
    search: { provider: 'local' },
    socialLinks: [{ icon: 'github', link: repo }],
    footer: {
      message: 'Vibe coded with Claude Code. Part of <a href="https://github.com/LouLouLibs">LouLouLibs</a>.',
      copyright: '© 2026 Erik Loualiche',
    },
  },
})
