require File.dirname(__FILE__) + '/support/setup'
require File.dirname(__FILE__) + '/support/document_mod_base'
require 'fileutils'

class RedactPages < DocumentModBase

  # The zoom ratio at which we'll be drawing redactions.
  ENLARGEMENT = 1000.0 / 700.0

  GM_ARGS = '-density 150 -limit memory 256MiB -limit map 512MiB'

  def process
    begin
      prepare_pdf
      redact
    rescue Exception => e
      fail_document
      LifecycleMailer.deliver_exception_notification(e, options)
      raise e
    end
    document.id
  end


  private

  def redact
    @page_text = {}
    Docsplit.extract_pages @pdf
    FileUtils.rm @pdf
    redactions_by_page = options['redactions'].group_by {|r| r['page'] }
    redactions_by_page.each {|page, redactions| redact_page page, redactions }
    rebuild_pdf
    rebuild_text
    document.reindex_all! access
  end

  def redact_page(page, redactions)
    base = "#{document.slug}_#{page}"

    # Make the list of image file paths.
    images = {}
    Page::IMAGE_SIZES.each do |size, geometry|
      images[size] = "#{base}_#{size}.gif"
    end

    # Get the large version of the page image.
    page_pdf_path  = "#{base}.pdf"
    page_tiff_path = "#{base}.tif"
    File.open(images['large'], 'w+') do |f|
      f.write(asset_store.read(document.page_image_path(page, 'large')))
    end

    # Draw black rectangular redactions on it.
    rectangles = redactions.map { |redaction|
      pos = redaction['location'].split(/,\s*/).map {|px| (px.to_i * ENLARGEMENT).round }
      gm_coords = [pos[3], pos[0], pos[1], pos[2]].join(',')
      "rectangle #{gm_coords}"
    }.join(' ')
    `gm mogrify #{GM_ARGS} #{images['large']} -fill black -draw "#{rectangles}" #{images['large']} 2>&1`

    # Downsize it to all smaller image sizes.
    previous = nil
    Page::IMAGE_SIZES.each do |size, geometry|
      if size != 'large'
        FileUtils.cp previous, images[size]
        `gm mogrify #{GM_ARGS} -unsharp 0x0.5+0.75 -resize #{geometry} #{images[size]} 2>&1`
      end
      previous = images[size]
    end

    # Save the redacted images to our asset store.
    asset_store.save_page_images(document, page, images, access)

    # Write out the new redacted pdf page, and tiff version for OCR.
    `gm convert #{GM_ARGS} #{images['large']} #{page_pdf_path} 2>&1`
    `gm convert #{GM_ARGS} -density 200x200 -colorspace GRAY #{images['large']} #{page_tiff_path} 2>&1`

    # OCR the large version of the image.
    `tesseract #{page_tiff_path} #{base} -l eng 2>&1`
    @page_text[page] = Docsplit.clean_text(DC::Import::Utils.read_ascii("#{base}.txt"))

  end

  # Create the new PDF for the full document, and save it to the asset store.
  def rebuild_pdf
    page_paths = (1..document.page_count).map {|i| "#{document.slug}_#{i}.pdf" }
    `pdftk #{page_paths.join(' ')} cat output #{@pdf}`
    asset_store.save_pdf(document, @pdf, access)
  end

  # Create all the new Page models, for pages that have been changed.
  def rebuild_text
    page_numbers = @page_text.keys
    Page.destroy_all "document_id = #{document.id} and page_number in (#{page_numbers.join(',')})"
    rows = @page_text.map do |pair|
      "(#{document.organization_id}, #{document.account_id}, #{document.id}, #{access}, #{pair[0]}, '#{PGconn.escape(pair[1])}')"
    end
    Page.connection.execute "insert into pages (organization_id, account_id, document_id, access, page_number, text) values #{rows.join(",\n")};"
  end

end
