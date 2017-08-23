# Smartclip
Smartclip is a contextually-aware paperclip processor that crops and scales your images to maximize aesthetic quality.

> While initially written as a passion project for [The Glass Files](https://www.theglassfiles.com/), I've abstracted away all the hardcoded specifics so it should work generically. Images smaller than the desired thumbnail size are automatically padded with a border rather than being enlarged.

## The Algorithm 
The algorithm is fairly simple and is an adjusted a port of [smartcrop.js](https://github.com/jwagner/smartcrop.js) by Jonas Wagner:
  * Find edges
  * Find regions with a color like skin
  * Find regions high in saturation
  * Generate a set of thumbnail candidates
  * Rank candidates using an importance function to focus the detail in the center and avoid it in the edges.
  * The highest ranking candidate is selected and is processed by Paperclip

## Example
The process is super simple, and is basically identical to using any other Paperclip processor:

  ```ruby
    # Your path might be different, so adjust as necessary
    require "#{Rails.root}/lib/paperclip_processors/smartclip"
    
    ...

    styles: { thumb: { resize_width: 150, resize_height: 150, processors: [:smartclip] } }
  ```

## Future Plans
  * Wrap within gem for easy installation
  * Optimize pixel iteration to reduce number of loops. Can it be done without screwing with saliency patterns?
  * Port and integrate face detection algorithm
  * Completely rewrite to favor deep neural networks? Benefits from more complicated criteria, and can be trained from professional data rather than guesses
