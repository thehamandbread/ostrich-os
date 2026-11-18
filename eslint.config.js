// eslint.config.js: lint GNOME Shell extensions (GJS, ES modules). Run with tests/lint-js.sh.
import js from '@eslint/js';
import globals from 'globals';

export default [
    js.configs.recommended,
    {
        files: ['modules/gnome/extensions/**/*.js', 'spikes/*-ext/**/*.js', 'tests/vm/*.js', 'tests/vm/critique/**/*.js'],
        languageOptions: {
            ecmaVersion: 2024,
            sourceType: 'module',
            globals: {
                ...globals.es2024,
                // GJS / GNOME Shell globals
                global: 'readonly',
                console: 'readonly',
                log: 'readonly',
                logError: 'readonly',
                print: 'readonly',
                printerr: 'readonly',
                imports: 'readonly',
                ARGV: 'readonly',
                TextEncoder: 'readonly',
                TextDecoder: 'readonly',
                setTimeout: 'readonly',
                clearTimeout: 'readonly',
                setInterval: 'readonly',
                clearInterval: 'readonly',
            },
        },
        rules: {
            'no-unused-vars': ['error', {argsIgnorePattern: '^_'}],
            'prefer-const': 'error',
            'no-var': 'error',
            'eqeqeq': ['error', 'always'],
            // GObject.registerClass(class X { ... }) keeps the class body at column 0, as in GNOME Shell.
            'indent': ['error', 4, {SwitchCase: 0, ignoredNodes: ['CallExpression > ClassExpression']}],
            'quotes': ['error', 'single', {avoidEscape: true, allowTemplateLiterals: true}],
            'semi': ['error', 'always'],
        },
    },
];
