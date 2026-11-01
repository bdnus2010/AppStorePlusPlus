#!/usr/bin/env python3
"""Render the official absolute-path SVG with Core Graphics on macOS."""
from pathlib import Path
import re, subprocess, xml.etree.ElementTree as ET
root = Path(__file__).resolve().parents[1]
svg = ET.parse(root/'Resources/BuyMeACoffee-logo.svg').getroot()
lines = ['import AppKit', 'let ctx = CGContext(data: nil, width: 140, height: 200, bitsPerComponent: 8, bytesPerRow: 560, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!', 'ctx.translateBy(x: 0, y: 200); ctx.scaleBy(x: 4, y: -4)']
for element in svg:
    assert element.tag.endswith('path')
    tokens = re.findall(r'[MLCHVZ]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?', element.attrib['d'])
    i = 0; command = None; x = y = sx = sy = 0
    lines.append('ctx.beginPath()')
    while i < len(tokens):
        if tokens[i].isalpha():
            command = tokens[i]; i += 1
        if command == 'Z':
            lines.append('ctx.closePath()'); x,y=sx,sy; command=None; continue
        count = {'M':2,'L':2,'C':6,'H':1,'V':1}[command]
        args = list(map(float,tokens[i:i+count])); assert len(args)==count; i+=count
        if command in ['M','L']:
            x,y=args
            lines.append(f'ctx.{"move" if command=="M" else "addLine"}(to: CGPoint(x: {x}, y: {y}))')
            if command=='M': sx,sy=x,y;command='L'
        elif command == 'C':
            a,b,c,d,x,y=args
            lines.append(f'ctx.addCurve(to: CGPoint(x: {x}, y: {y}), control1: CGPoint(x: {a}, y: {b}), control2: CGPoint(x: {c}, y: {d}))')
        else:
            if command=='H': x=args[0]
            else: y=args[0]
            lines.append(f'ctx.addLine(to: CGPoint(x: {x}, y: {y}))')
    color=element.attrib['fill'].lstrip('#');assert len(color)==6
    rgb=[int(color[n:n+2],16)/255 for n in [0,2,4]]
    lines.append(f'ctx.setFillColor(red: {rgb[0]}, green: {rgb[1]}, blue: {rgb[2]}, alpha: 1); ctx.fillPath()')
lines += ['let bitmap = NSBitmapImageRep(cgImage: ctx.makeImage()!)', 'try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))']
build=root/'build';build.mkdir(exist_ok=True)
script=build/'render-coffee-logo.swift';script.write_text('\n'.join(lines)+'\n')
subprocess.run(['swift','-module-cache-path',str(build/'module-cache'),str(script),str(root/'Resources/BuyMeACoffee.png')],check=True)
