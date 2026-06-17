/* global hexo */

'use strict';

const fs = require('fs');
const path = require('path');

function overrideInject(type, relativePath) {
  const absolutePath = path.join(hexo.base_dir, relativePath);
  const layoutName = `inject/${type}/default.ejs`;

  hexo.theme.setView(layoutName, fs.readFileSync(absolutePath, 'utf8'));
  hexo.theme.config.injects[type] = [{
    layout: layoutName,
    order: 0
  }];
}

function overrideView(viewName, relativePath) {
  const absolutePath = path.join(hexo.base_dir, relativePath);
  hexo.theme.setView(viewName, fs.readFileSync(absolutePath, 'utf8'));
}

hexo.extend.filter.register('before_generate', function() {
  overrideInject('header', path.join('layout', '_partials', 'header.ejs'));
  overrideInject('postMetaTop', path.join('layout', '_partials', 'post', 'meta-top.ejs'));
  overrideInject('postMetaBottom', path.join('layout', '_partials', 'post', 'meta-bottom.ejs'));
  overrideView('index.ejs', path.join('layout', 'index.ejs'));
  overrideView('post.ejs', path.join('layout', 'post.ejs'));
}, 100);
