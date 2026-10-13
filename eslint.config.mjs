// Repo-only ESLint 9 flat config: no imports, no extra packages.
export default [
  {
    files: ['**/*.{js,mjs,cjs}'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module', // change to 'script' if you’re not using ESM
      // Common globals (browser + Node) — add/remove as needed
      globals: {
        window: true, document: true, navigator: true, location: true,
        console: true, fetch: true, URL: true, setTimeout: true,
        setInterval: true, clearTimeout: true, clearInterval: true,
        module: true, require: true, __dirname: true, process: true
      }
    },
    rules: {
      // minimal but useful core rules
      'no-undef': 'error',
      'no-unused-vars': 'warn',
      'no-redeclare': 'error',
      'no-constant-condition': ['warn', { checkLoops: false }],
      'no-cond-assign': ['error', 'except-parens'],
      'eqeqeq': 'warn',
      'no-var': 'warn',
      'prefer-const': 'warn',
      'no-console': 'off'
    }
  }
];
