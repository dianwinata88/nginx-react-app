import { describe, expect, it } from 'vitest'
import { createElement } from 'react'
import App from './App'

describe('App', () => {
  it('is a valid React component', () => {
    expect(createElement(App)).toBeTruthy()
  })
})
